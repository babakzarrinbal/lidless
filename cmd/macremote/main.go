// Command macremote is the Mac side of Mac Remote: it keeps an outbound
// connection to the relay and serves terminals and files to paired phones
// over an end-to-end encrypted Noise IK channel.
//
//	macremote init -relay host:port -pin <sha256>   create keys and config
//	macremote pair [-code] [-png file]              pair a phone (QR, 10 min)
//	macremote devices                               list paired phones
//	macremote revoke <n|name>                       remove a phone
//	macremote install | uninstall                   LaunchAgent (starts at login)
//	macremote status                                config + agent state
//	macremote serve                                 run in the foreground
package main

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

const label = "org.zarrinbal.macremote"

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "macremote: "+format+"\n", a...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: macremote init|pair|devices|revoke|install|uninstall|status|serve")
		os.Exit(2)
	}
	args := os.Args[2:]
	switch os.Args[1] {
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

type pairCode struct {
	Relay string `json:"r"`
	Pin   string `json:"p"`
	Room  string `json:"m"`
	Key   string `json:"k"`
	Token string `json:"t"`
	Host  string `json:"n"`
}

func cmdPair(args []string) {
	fs := flag.NewFlagSet("pair", flag.ExitOnError)
	codeOnly := fs.Bool("code", false, "print only the pairing code and exit")
	png := fs.String("png", "", "also write the QR code to this PNG file")
	fs.Parse(args)
	c, err := loadConfig()
	if err != nil {
		die("%v", err)
	}
	p := Pairing{Token: randHex(16), Expires: time.Now().Add(10 * time.Minute)}
	if err := writeJSON0600(pairingPath(), p); err != nil {
		die("%v", err)
	}
	b, _ := json.Marshal(pairCode{c.Relay, c.Pin, c.Room, c.Pub, p.Token, computerName()})
	code := "mr1." + base64.RawURLEncoding.EncodeToString(b)
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
	fmt.Println("\nScan this in Mac Remote on the phone (valid 10 minutes, one phone).")
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
		die("usage: macremote revoke <n|name>")
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
		die("no such phone; see `macremote devices`")
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
	return filepath.Join(home, "Library", "Application Support", "MacRemote")
}

func plistPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", label+".plist")
}

func logPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Logs", "macremote.log")
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
	if _, err := loadConfig(); err != nil {
		die("%v", err)
	}
	exe, err := os.Executable()
	if err != nil {
		die("%v", err)
	}
	if err := os.MkdirAll(supportDir(), 0o700); err != nil {
		die("%v", err)
	}
	bin := filepath.Join(supportDir(), "macremote")
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
	<key>StandardOutPath</key><string>%s</string>
	<key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, label, bin, logPath(), logPath())
	os.MkdirAll(filepath.Dir(plistPath()), 0o755)
	if err := os.WriteFile(plistPath(), []byte(plist), 0o644); err != nil {
		die("%v", err)
	}
	launchctl("bootout", domain()+"/"+label) // fine if it was not loaded
	if err := launchctl("bootstrap", domain(), plistPath()); err != nil {
		die("%v", err)
	}
	fmt.Println("installed; the agent starts at login. Log:", logPath())
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
	fmt.Printf("relay   %s\nphones  %d\nroots   %s\n", c.Relay, len(c.Devices), strings.Join(c.Roots, ", "))
	if exec.Command("launchctl", "print", domain()+"/"+label).Run() == nil {
		fmt.Println("agent   running (LaunchAgent)")
	} else {
		fmt.Println("agent   not installed")
	}
}

func cmdServe() {
	c, err := loadConfig()
	if err != nil {
		die("%v", err)
	}
	if c.RoomKey == "" { // configs from before the relay checked agents
		c.RoomKey = randHex(32)
		if err := c.save(); err != nil {
			die("%v", err)
		}
	}
	st, _ := os.Stat(configPath())
	a := &Agent{cfg: c, cfgMtime: st.ModTime(), host: computerName(), terms: newTerms(), sessions: map[*Session]struct{}{}}
	if c.KeepAwake {
		// Prevent idle sleep for as long as this process lives.
		cmd := exec.Command("caffeinate", "-i", "-w", strconv.Itoa(os.Getpid()))
		if err := cmd.Start(); err != nil {
			logf("caffeinate: %v", err)
		}
	}
	go func() {
		for range time.Tick(5 * time.Second) {
			a.reload()
		}
	}()
	logf("macremote serving %q, %d paired phone(s)", a.host, len(c.Devices))
	a.run()
}
