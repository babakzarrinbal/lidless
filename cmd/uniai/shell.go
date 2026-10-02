package main

import (
	"os"
	"os/exec"
	"os/user"
	"strings"

	"uniai/internal/config"
)

// shells lists the login shells this Mac offers (/etc/shells), those that exist.
func shells() []string {
	b, _ := os.ReadFile("/etc/shells")
	return parseShells(string(b), func(p string) bool {
		st, err := os.Stat(p)
		return err == nil && !st.IsDir() && st.Mode()&0o111 != 0
	})
}

func parseShells(s string, exists func(string) bool) []string {
	var out []string
	seen := map[string]bool{}
	for _, l := range strings.Split(s, "\n") {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") || !strings.HasPrefix(l, "/") || seen[l] || !exists(l) {
			continue
		}
		seen[l] = true
		out = append(out, l)
	}
	return out
}

// loginShell is the account's shell (System Settings › Users), which a
// LaunchAgent's $SHELL may not match.
func loginShell() string {
	if u, err := user.Current(); err == nil {
		if b, err := exec.Command("dscl", ".", "-read", "/Users/"+u.Username, "UserShell").Output(); err == nil {
			if f := strings.Fields(string(b)); len(f) == 2 && strings.HasPrefix(f[1], "/") {
				return f[1]
			}
		}
	}
	if s := os.Getenv("SHELL"); s != "" {
		return s
	}
	return "/bin/zsh"
}

// pickShell is the shell for a new terminal: the one asked for when this Mac
// offers it, else the Mac's default (set from the phone), else the login shell.
func pickShell(want, def string, offered []string) string {
	for _, s := range []string{want, def} {
		if s != "" && contains(offered, s) {
			return s
		}
	}
	return loginShell()
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func shellInfo(cfg *config.Config) map[string]any {
	return map[string]any{"shells": shells(), "default": cfg.Shell, "login": loginShell()}
}

// setShell makes shell (or, when empty, the login shell) the default for new terminals.
func (a *Agent) setShell(shell string) error {
	if shell != "" && !contains(shells(), shell) {
		return &rpcError{Code: "bad", Msg: "this Mac does not offer " + shell}
	}
	a.reload() // don't write back a stale copy (a `revoke` since)
	a.mu.Lock()
	nc := *a.cfg
	nc.Shell = shell
	a.mu.Unlock()
	if err := nc.Save(); err != nil {
		return err
	}
	a.reload()
	return nil
}
