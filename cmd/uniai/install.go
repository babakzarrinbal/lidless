// Installing the core on this Mac: the LaunchAgent (org.zarrinbal.uniai)
// that runs ~/Library/Application Support/Uniai/uniai at login, the `uniai`
// command (~/.local/bin/uniai), and on the first install the claude/copilot
// shell aliases. The Mac app carries its core (Contents/MacOS/uniai) and runs
// `uniai install -if-newer` at every start, so installing (or updating) the app
// is all a Mac needs; an app built with the relay in Contents/Resources/relay (dev.sh
// mac-app) also points a new Mac at it. docs/architecture.md covers the rest.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"uniai/internal/config"
)

func plistPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", label+".plist")
}

func logPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Logs", "uniai.log")
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".new"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}

// version is when this core was built (dev.sh stamps it, UTC
// yyyymmdd.hhmmss); "dev" for a plain go build.
var version = "dev"

// replaces is whether a core built at mine should replace the one built at
// theirs ("" when it is too old to say): only a newer stamp does.
func replaces(mine, theirs string) bool {
	stamp := func(v string) bool { return len(v) == 15 && v[8] == '.' }
	return !stamp(theirs) || (stamp(mine) && mine > theirs)
}

// installedVersion is the stamp of the LaunchAgent's core, "" when it has
// none or is not running.
func installedVersion(bin string) string {
	if launchctl("print", domain()+"/"+label) != nil {
		return ""
	}
	out, err := exec.Command(bin, "version").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func launchctl(args ...string) error {
	out, err := exec.Command("launchctl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func domain() string { return "gui/" + strconv.Itoa(os.Getuid()) }

// bundledRelay is the relay an app bundle carries next to this binary
// (Contents/Resources/relay: "host:port pin"), or "" outside one.
func bundledRelay(exe string) (relay, pin string) {
	b, err := os.ReadFile(filepath.Join(filepath.Dir(exe), "..", "Resources", "relay"))
	if err != nil {
		return "", ""
	}
	f := strings.Fields(string(b))
	if len(f) != 2 || len(f[1]) != 64 {
		return "", ""
	}
	return f[0], f[1]
}

func cmdInstall(args []string) {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	ifNewer := fs.Bool("if-newer", false, "do nothing unless this core is newer than the running one (the Mac app, at every start)")
	fs.Parse(args)
	exe := must(os.Executable())
	bin := filepath.Join(config.SupportDir(), "uniai")
	if *ifNewer && !replaces(version, installedVersion(bin)) {
		return
	}
	c, err := config.Ensure()
	if err != nil {
		die("%v", err)
	}
	if relay, pin := bundledRelay(exe); c.Relay == "" && relay != "" {
		c.Relay, c.Pin = relay, pin
		if err := c.Save(); err != nil {
			die("%v", err)
		}
		fmt.Println("relay set from the app; pair a phone from the app's Devices page")
	}
	if brewServiceLoaded() {
		die("%s; `install` would start a second copy", brewServiceHint())
	}
	if err := os.MkdirAll(config.SupportDir(), 0o700); err != nil {
		die("%v", err)
	}
	if exe != bin {
		if err := copyFile(exe, bin); err != nil {
			die("%v", err)
		}
	}
	_, err = os.Stat(plistPath())
	first := os.IsNotExist(err)
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>%s</string>
	<key>ProgramArguments</key><array><string>%s</string><string>serve</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ProcessType</key><string>Interactive</string>
	<key>AbandonProcessGroup</key><true/>
	<key>StandardOutPath</key><string>%s</string>
	<key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, label, bin, logPath(), logPath())
	os.MkdirAll(filepath.Dir(plistPath()), 0o755)
	if err := os.WriteFile(plistPath(), []byte(plist), 0o644); err != nil {
		die("%v", err)
	}
	// Run from a phone's terminal, stopping the agent can end this process
	// (an agent from before holders took its terminals with it), and the
	// agent would never start again: a detached copy restarts it.
	log, err := os.OpenFile(logPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		die("%v", err)
	}
	cmd := exec.Command(bin, "reload")
	cmd.Stdout, cmd.Stderr = log, log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		die("%v", err)
	}
	if err := cmd.Wait(); err != nil {
		die("restarting the agent failed (%v); see %s", err, logPath())
	}
	linkCLI(bin)
	if first {
		cmdShellSetup(nil)
	}
	fmt.Println("installed; the agent starts at login. Log:", logPath())
}

// linkCLI puts `uniai` in ~/.local/bin, pointing at the LaunchAgent's copy.
func linkCLI(bin string) {
	home, _ := os.UserHomeDir()
	link := filepath.Join(home, ".local", "bin", "uniai")
	if cur, err := os.Readlink(link); err == nil && cur == bin {
		return
	} else if _, serr := os.Lstat(link); serr == nil && err != nil {
		return // a file of someone else's: leave it
	}
	os.MkdirAll(filepath.Dir(link), 0o755)
	os.Remove(link)
	if err := os.Symlink(bin, link); err != nil {
		fmt.Fprintln(os.Stderr, "uniai: could not link", link+":", err)
	}
}

// cmdReload (re)starts the LaunchAgent; `install` runs it detached.
func cmdReload() {
	launchctl("bootout", domain()+"/"+label) // fine if it was not loaded
	// The old agent may still be stopping: bootstrap then fails with EIO.
	err := launchctl("bootstrap", domain(), plistPath())
	for i := 0; err != nil && i < 10; i++ {
		time.Sleep(500 * time.Millisecond)
		err = launchctl("bootstrap", domain(), plistPath())
	}
	if err != nil {
		die("reload: %v", err)
	}
}

func cmdUninstall() {
	launchctl("bootout", domain()+"/"+label)
	os.Remove(plistPath())
	fmt.Println("agent stopped and removed from login (config kept in", config.Dir()+")")
}
