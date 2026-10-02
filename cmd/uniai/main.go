// Command uniai is the Mac side of bz-uniai: it keeps an outbound
// connection to the relay and serves terminals and files to paired phones
// over an end-to-end encrypted Noise IK channel.
//
//	uniai setup host:port [-pin <sha256>]       set up, start, pair: all a new Mac needs
//	uniai init -relay host:port -pin <sha256>   create keys and config only
//	uniai pair [-code] [-png file]              pair a phone (QR, 10 min)
//	uniai devices                               list paired phones
//	uniai revoke <n|name>                       remove a phone
//	uniai install | uninstall                   LaunchAgent (starts at login)
//	uniai status                                config + agent state
//	uniai serve                                 run in the foreground
//	uniai ls                                    the Mac's shared terminals
//	uniai attach [id|folder]                    join one in this window (Ctrl-] leaves it)
//	uniai kill <id>                             end one on every device
//	uniai claude|copilot [args]                 start (or join) one, shared with the phones
//	uniai shell-setup                           alias claude/copilot to the above in ~/.zshrc
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	qrcode "github.com/skip2/go-qrcode"

	"uniai/internal/rpc"
	"uniai/internal/ulog"
)

const label = "org.zarrinbal.uniai"

var logf = ulog.Logf

// rpcError is rpc.Error: a code the app can read.
type rpcError = rpc.Error

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "uniai: "+format+"\n", a...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: uniai setup|init|pair|devices|revoke|install|uninstall|status|serve|statusline [install]|usage|ls [--json]|attach|kill|claude|copilot|shell-setup|vscode")
		os.Exit(2)
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "setup":
		cmdSetup(args)
	case "init":
		cmdInit(args)
	case "pair":
		cmdPair(args)
	case "devices":
		cmdDevices()
	case "revoke":
		cmdRevoke(args)
	case "install":
		cmdInstall()
	case "uninstall":
		cmdUninstall()
	case "status":
		cmdStatus()
	case "serve":
		cmdServe()
	case "statusline":
		cmdStatusline(args)
	case "usage":
		cmdUsage()
	case "hold":
		cmdHold(args)
	case "reload":
		cmdReload()
	case "ls":
		cmdLs(args)
	case "attach":
		cmdAttach(args)
	case "kill":
		cmdKill(args)
	case "claude", "copilot":
		cmdAgentCLI(os.Args[1], args)
	case "shell-setup":
		cmdShellSetup(args)
	case "vscode":
		cmdVSCode(args)
	default:
		die("unknown command %q", os.Args[1])
	}
}

func cmdInit(args []string) {
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	relay := fs.String("relay", "", "relay host:port")
	pin := fs.String("pin", "", "sha256 of the relay certificate")
	force := fs.Bool("force", false, "replace an existing config (unpairs every phone)")
	fs.Parse(args)
	if *relay == "" || len(*pin) != 64 {
		die("init needs -relay host:port and a 64-hex -pin")
	}
	if c, err := loadConfig(); err == nil {
		if !*force {
			// Keep keys and phones; only point at the (new) relay.
			c.Relay, c.Pin = *relay, *pin
			if err := c.save(); err != nil {
				die("%v", err)
			}
			fmt.Println("updated relay in", configPath())
			return
		}
	}
	c, err := newConfig(*relay, *pin)
	if err != nil {
		die("%v", err)
	}
	if err := c.save(); err != nil {
		die("%v", err)
	}
	fmt.Println("created", configPath())
}

func cmdPair(args []string) {
	fs := flag.NewFlagSet("pair", flag.ExitOnError)
	codeOnly := fs.Bool("code", false, "print only the pairing code and exit")
	png := fs.String("png", "", "also write the QR code to this PNG file")
	fs.Parse(args)
	c, err := loadConfig()
	if err == nil && c.Relay == "" {
		err = errNotSetUp
	}
	if err != nil {
		die("%v", err)
	}
	code, p, err := newPairCode(c)
	if err != nil {
		die("%v", err)
	}
	if *codeOnly {
		fmt.Println(code)
		return
	}
	q, err := qrcode.New(code, qrcode.Low)
	if err != nil {
		die("%v", err)
	}
	if *png != "" {
		if err := q.WriteFile(512, *png); err != nil {
			die("%v", err)
		}
	}
	fmt.Print(q.ToSmallString(false))
	fmt.Println("\nScan this in bz-uniai on the phone (valid 10 minutes, one phone).")
	before := len(c.Devices)
	for time.Now().Before(p.Expires) {
		time.Sleep(time.Second)
		if c2, err := loadConfig(); err == nil && len(c2.Devices) > before {
			fmt.Printf("Paired: %s\n", c2.Devices[len(c2.Devices)-1].Name)
			return
		}
	}
	os.Remove(pairingPath())
	die("pairing code expired")
}

func cmdDevices() {
	c, err := loadConfig()
	if err != nil {
		die("%v", err)
	}
	if len(c.Devices) == 0 {
		fmt.Println("no paired phones")
	}
	for i, d := range c.Devices {
		fmt.Printf("%d  %-28s added %s  key %s…\n", i+1, d.Name, d.Added.Format("2006-01-02 15:04"), d.Pub[:12])
	}
}

func cmdRevoke(args []string) {
	if len(args) != 1 {
		die("usage: uniai revoke <n|name>")
	}
	c, err := loadConfig()
	if err != nil {
		die("%v", err)
	}
	idx := -1
	if n, err := strconv.Atoi(args[0]); err == nil && n >= 1 && n <= len(c.Devices) {
		idx = n - 1
	} else {
		for i, d := range c.Devices {
			if d.Name == args[0] {
				idx = i
			}
		}
	}
	if idx < 0 {
		die("no such phone; see `uniai devices`")
	}
	name := c.Devices[idx].Name
	c.Devices = append(c.Devices[:idx], c.Devices[idx+1:]...)
	if err := c.save(); err != nil {
		die("%v", err)
	}
	fmt.Printf("removed %s (its open sessions close within seconds)\n", name)
}

func supportDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Uniai")
}

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

func launchctl(args ...string) error {
	out, err := exec.Command("launchctl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func domain() string { return "gui/" + strconv.Itoa(os.Getuid()) }

func cmdInstall() {
	if _, err := ensureConfig(); err != nil {
		die("%v", err)
	}
	if brewServiceLoaded() {
		die("%s; `install` would start a second copy", brewServiceHint())
	}
	exe, err := os.Executable()
	if err != nil {
		die("%v", err)
	}
	if err := os.MkdirAll(supportDir(), 0o700); err != nil {
		die("%v", err)
	}
	bin := filepath.Join(supportDir(), "uniai")
	if exe != bin {
		if err := copyFile(exe, bin); err != nil {
			die("%v", err)
		}
	}
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
	fmt.Println("installed; the agent starts at login. Log:", logPath())
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
	fmt.Println("agent stopped and removed from login (config kept in", configDir()+")")
}

func cmdStatus() {
	c, err := loadConfig()
	if err != nil {
		die("%v", err)
	}
	relay := c.Relay
	if relay == "" {
		relay = "none (this Mac's app only; `uniai setup` adds one)"
	}
	fmt.Printf("relay   %s\nphones  %d\nroots   %s\n", relay, len(c.Devices), strings.Join(c.Roots, ", "))
	la, bs := launchctl("print", domain()+"/"+label) == nil, brewServiceLoaded()
	switch {
	case la && bs:
		fmt.Println("agent   TWO copies (LaunchAgent and brew service): they knock each other off the relay.\n        Keep one: `uniai uninstall`, then `brew services restart uniai`")
	case la:
		fmt.Println("agent   running (LaunchAgent)")
	case bs:
		fmt.Println("agent   running (brew services)")
	default:
		fmt.Println("agent   not installed")
	}
}

func cmdServe() {
	holdAgentLock()
	c, err := ensureConfig()
	if err != nil {
		die("%v", err)
	}
	if msg := statuslineEnsure(); msg != "" {
		logf("%s", msg)
	}
	keepCounting()
	if c.RoomKey == "" { // configs from before the relay checked agents
		c.RoomKey = randHex(32)
		if err := c.save(); err != nil {
			die("%v", err)
		}
	}
	st, _ := os.Stat(configPath())
	a := &Agent{cfg: c, cfgMtime: st.ModTime(), host: computerName(), terms: newTerms(), plugins: corePlugins(), sessions: map[*Session]struct{}{}}
	a.terms.onChange = a.termsChanged
	a.terms.onEvent = a.termEvent
	go a.terms.watch() // adopts the terminals that outlived the last agent
	go a.terms.mirrorVSCode()
	if c.KeepAwake {
		// Prevent idle sleep for as long as this process lives.
		cmd := exec.Command("caffeinate", "-i", "-w", strconv.Itoa(os.Getpid()))
		if err := cmd.Start(); err != nil {
			logf("caffeinate: %v", err)
		}
	}
	if runtime.GOOS == "darwin" {
		go keepDisplayOffWhenShut()
	}
	go func() {
		for range time.Tick(5 * time.Second) {
			a.reload()
		}
	}()
	go a.serveLocal()
	if c.Relay == "" {
		logf("no relay set: serving only this Mac's app until `uniai setup`")
	}
	logf("uniai serving %q, %d paired phone(s)", a.host, len(c.Devices))
	a.run()
}
