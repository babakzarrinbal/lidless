// Command uniai is the Mac side of bz-uniai: it keeps an outbound
// connection to the relay and serves terminals and files to paired phones
// over an end-to-end encrypted Noise IK channel.
//
//	uniai setup host:port [-pin <sha256>]       set up, start, pair: all a new Mac needs
//	uniai init -relay host:port -pin <sha256>   create keys and config only
//	uniai pair [-code] [-png file]              pair a phone (QR, 10 min)
//	uniai devices                               list paired phones
//	uniai revoke <n|name>                       remove a phone
//	uniai install [-if-newer] | uninstall       LaunchAgent (starts at login), the uniai command, shell aliases
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
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"

	"uniai/internal/config"
	"uniai/internal/holder"
	"uniai/internal/rpc"
	"uniai/internal/ulog"
	"uniai/internal/usage"
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
		fmt.Fprintln(os.Stderr, "usage: uniai setup|init|pair|devices|revoke|install|uninstall|status|serve|statusline [install]|usage|ls [--json]|attach|kill|claude|copilot|shell-setup|version")
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
		cmdInstall(args)
	case "uninstall":
		cmdUninstall()
	case "status":
		cmdStatus()
	case "serve":
		cmdServe()
	case "statusline":
		usage.CmdStatusline(args)
	case "usage":
		usage.CmdUsage()
	case "hold":
		holder.Run(args)
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
	case "version":
		fmt.Println(version)
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
	if c, err := config.Load(); err == nil {
		if !*force {
			// Keep keys and phones; only point at the (new) relay.
			c.Relay, c.Pin = *relay, *pin
			if err := c.Save(); err != nil {
				die("%v", err)
			}
			fmt.Println("updated relay in", config.Path())
			return
		}
	}
	c, err := config.New(*relay, *pin)
	if err != nil {
		die("%v", err)
	}
	if err := c.Save(); err != nil {
		die("%v", err)
	}
	fmt.Println("created", config.Path())
}

func cmdPair(args []string) {
	fs := flag.NewFlagSet("pair", flag.ExitOnError)
	codeOnly := fs.Bool("code", false, "print only the pairing code and exit")
	png := fs.String("png", "", "also write the QR code to this PNG file")
	fs.Parse(args)
	c, err := config.Load()
	if err == nil && c.Relay == "" {
		err = config.ErrNotSetUp
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
		if c2, err := config.Load(); err == nil && len(c2.Devices) > before {
			fmt.Printf("Paired: %s\n", c2.Devices[len(c2.Devices)-1].Name)
			return
		}
	}
	os.Remove(config.PairingPath())
	die("pairing code expired")
}

func cmdDevices() {
	c, err := config.Load()
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
	c, err := config.Load()
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
	if err := c.Save(); err != nil {
		die("%v", err)
	}
	fmt.Printf("removed %s (its open sessions close within seconds)\n", name)
}

func cmdStatus() {
	c, err := config.Load()
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
	c, err := config.Ensure()
	if err != nil {
		die("%v", err)
	}
	if msg := usage.StatuslineEnsure(); msg != "" {
		logf("%s", msg)
	}
	usage.KeepCounting()
	if c.RoomKey == "" { // configs from before the relay checked agents
		c.RoomKey = config.RandHex(32)
		if err := c.Save(); err != nil {
			die("%v", err)
		}
	}
	st, _ := os.Stat(config.Path())
	a := &Agent{cfg: c, cfgMtime: st.ModTime(), host: computerName(), terms: newTerms(), plugins: corePlugins(), sessions: map[*Session]struct{}{}}
	a.terms.onChange = a.termsChanged
	a.terms.onEvent = a.termEvent
	go a.terms.watch() // adopts the terminals that outlived the last agent
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
