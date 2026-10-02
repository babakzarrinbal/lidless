package main

import (
	"bufio"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"uniai/internal/config"
)

// cmdSetup is the one command a new Mac needs: point at a relay, start the
// agent (as a brew service when brew installed it, else a LaunchAgent) and
// show a pairing code.
//
//	uniai setup relay.example.com:8460 [-pin <sha256>]
//
// Without -pin it shows the relay's certificate pin to compare with
// `relay pin` on the server before trusting it.
func cmdSetup(args []string) {
	fs := flag.NewFlagSet("setup", flag.ExitOnError)
	pin := fs.String("pin", "", "sha256 of the relay certificate (`docker exec uniai-relay /relay pin` on the server)")
	noPair := fs.Bool("no-pair", false, "don't show a pairing code at the end")
	relay := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		relay, args = args[0], args[1:]
	}
	fs.Parse(args)
	if relay == "" && fs.NArg() > 0 {
		relay = fs.Arg(0)
	}
	if relay == "" {
		die("usage: uniai setup host:port [-pin <sha256>]")
	}
	if _, _, err := net.SplitHostPort(relay); err != nil {
		relay = net.JoinHostPort(relay, "8460")
	}
	got, err := relayPin(relay)
	if err != nil {
		die("can't reach the relay at %s: %v", relay, err)
	}
	switch {
	case *pin == "":
		fmt.Printf("The relay at %s has certificate pin\n  %s\n", relay, got)
		if fi, err := os.Stdin.Stat(); err != nil || fi.Mode()&os.ModeCharDevice == 0 {
			die("check it against `relay pin` on the server, then run again with -pin %s", got)
		}
		fmt.Print("Is that what `relay pin` shows on the server? [y/N] ")
		a, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		if a = strings.ToLower(strings.TrimSpace(a)); a != "y" && a != "yes" {
			die("not set up")
		}
	case !strings.EqualFold(*pin, got):
		die("the relay at %s presents pin %s, not %s: wrong server, or something in between", relay, got, *pin)
	}

	c, err := config.Load()
	if err == nil {
		c.Relay, c.Pin = relay, got // keys and phones stay
	} else if c, err = config.New(relay, got); err != nil {
		die("%v", err)
	}
	if err := c.Save(); err != nil {
		die("%v", err)
	}
	fmt.Println("relay set in", config.Path())

	if brew := brewInstalled(); brew != "" {
		if _, err := os.Stat(plistPath()); err == nil {
			cmdUninstall() // an older install.sh copy: only one agent may run
		}
		out, err := exec.Command(brew, "services", "restart", "uniai").CombinedOutput()
		if err != nil {
			die("brew services restart uniai: %v\n%s", err, out)
		}
		fmt.Println("agent running (brew services); it starts at every login")
	} else {
		cmdInstall()
	}
	if !*noPair {
		fmt.Println()
		cmdPair(nil)
	}
}

// relayPin fetches the relay's certificate and returns its sha256.
func relayPin(addr string) (string, error) {
	d := &net.Dialer{Timeout: 10 * time.Second}
	conn, err := tls.DialWithDialer(d, "tcp", addr, &tls.Config{MinVersion: tls.VersionTLS13, InsecureSkipVerify: true}) // the pin is what's checked
	if err != nil {
		return "", err
	}
	defer conn.Close()
	certs := conn.ConnectionState().PeerCertificates
	if len(certs) == 0 {
		return "", fmt.Errorf("no certificate")
	}
	sum := sha256.Sum256(certs[0].Raw)
	return hex.EncodeToString(sum[:]), nil
}

// brewInstalled returns the brew binary when this uniai came from a
// Homebrew Cellar, else "".
func brewInstalled() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	i := strings.Index(exe, "/Cellar/uniai/")
	if i < 0 {
		return ""
	}
	if b := filepath.Join(exe[:i], "bin", "brew"); fileExists(b) {
		return b
	}
	if b, err := exec.LookPath("brew"); err == nil {
		return b
	}
	return ""
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
