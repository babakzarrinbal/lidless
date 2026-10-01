package main

// Context window (and, from older Claude Code versions, plan limits), as
// Claude Code reports them: it hands its status line command a JSON snapshot
// after every answer. `macremote statusline` is that command; it keeps the
// latest snapshot per session here, prints a short line for the terminal, and
// the phone reads the snapshots. Plan limits now come from limits.go.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var reSessionID = regexp.MustCompile(`^[A-Za-z0-9-]{8,64}$`)

func statusDir() string { return filepath.Join(supportDir(), "claude-status") }

type ctxWindow struct {
	TotalInput   int64   `json:"total_input_tokens"`
	Size         int64   `json:"context_window_size"`
	UsedPct      float64 `json:"used_percentage"`
	CurrentUsage *struct {
		Input         int64 `json:"input_tokens"`
		CacheCreation int64 `json:"cache_creation_input_tokens"`
		CacheRead     int64 `json:"cache_read_input_tokens"`
	} `json:"current_usage"`
}

type statusSnap struct {
	SessionID string `json:"session_id"`
	Model     struct {
		ID          string `json:"id"`
		DisplayName string `json:"display_name"`
	} `json:"model"`
	ContextWindow *ctxWindow                 `json:"context_window,omitempty"`
	RateLimits    map[string]json.RawMessage `json:"rate_limits,omitempty"`
	At            int64                      `json:"at"`
	Account       string                     `json:"account,omitempty"` // who was signed in
}

// cmdStatusline is Claude Code's status line command.
func cmdStatusline(args []string) {
	if len(args) > 0 && args[0] == "install" {
		statuslineInstall()
		return
	}
	b, _ := io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
	var s statusSnap
	if json.Unmarshal(b, &s) != nil {
		return
	}
	s.At = time.Now().Unix()
	home, _ := os.UserHomeDir()
	s.Account = claudeAccountEmail(filepath.Join(home, ".claude"))
	if reSessionID.MatchString(s.SessionID) {
		os.MkdirAll(statusDir(), 0o700)
		out, _ := json.Marshal(s)
		p := filepath.Join(statusDir(), s.SessionID+".json")
		if os.WriteFile(p+".tmp", out, 0o600) == nil {
			os.Rename(p+".tmp", p)
		}
		pruneStatus()
	}
	fmt.Println(statusLine(s))
}

func statusLine(s statusSnap) string {
	parts := []string{}
	if s.Model.DisplayName != "" {
		parts = append(parts, s.Model.DisplayName)
	}
	if used, size := s.ContextWindow.used(); size > 0 {
		parts = append(parts, fmt.Sprintf("ctx %s/%s", tokens(used), tokens(size)))
	}
	for _, k := range []string{"five_hour", "seven_day"} {
		if w, ok := limitOf(s.RateLimits[k]); ok {
			parts = append(parts, fmt.Sprintf("%s %.0f%%", map[string]string{"five_hour": "5h", "seven_day": "7d"}[k], w.Pct))
		}
	}
	return strings.Join(parts, " · ")
}

func (c *ctxWindow) used() (used, size int64) {
	if c == nil {
		return 0, 0
	}
	if u := c.CurrentUsage; u != nil {
		used = u.Input + u.CacheCreation + u.CacheRead
	} else {
		used = int64(c.UsedPct * float64(c.Size) / 100)
	}
	return used, c.Size
}

func tokens(n int64) string {
	switch {
	case n >= 1_000_000:
		return strconv.FormatFloat(float64(n)/1e6, 'f', 1, 64) + "M"
	case n >= 1000:
		return strconv.FormatInt(n/1000, 10) + "k"
	}
	return strconv.FormatInt(n, 10)
}

type limit struct {
	Pct    float64 `json:"pct"`
	Resets int64   `json:"resets"`
}

func limitOf(raw json.RawMessage) (limit, bool) {
	var w struct {
		Used   *float64 `json:"used_percentage"`
		Resets int64    `json:"resets_at"`
	}
	if raw == nil || json.Unmarshal(raw, &w) != nil || w.Used == nil {
		return limit{}, false
	}
	return limit{*w.Used, w.Resets}, true
}

func pruneStatus() {
	files, _ := filepath.Glob(filepath.Join(statusDir(), "*.json"))
	if len(files) < 50 {
		return
	}
	for _, f := range files {
		if st, err := os.Stat(f); err == nil && time.Since(st.ModTime()) > 14*24*time.Hour {
			os.Remove(f)
		}
	}
}

func readStatus(sid string) *statusSnap {
	if !reSessionID.MatchString(sid) {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(statusDir(), sid+".json"))
	if err != nil {
		return nil
	}
	var s statusSnap
	if json.Unmarshal(b, &s) != nil {
		return nil
	}
	return &s
}

// claudeUsage is the newest plan usage any session of the signed-in account
// saw, the account, and the tokens counted per account.
func claudeUsage() map[string]any {
	out := map[string]any{"limits": map[string]limit{}, "at": 0, "statusline": statuslineInstalled(), "tokens": tokenLedger.tokenTotals()}
	var asked, copilot map[string]any
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); asked = claudeLimits() }()
	go func() { defer wg.Done(); copilot = copilotQuota() }()
	wg.Wait()
	if copilot != nil {
		out["copilot"] = copilot
	}
	home, _ := os.UserHomeDir()
	who := claudeAccountEmail(filepath.Join(home, ".claude"))
	files, _ := filepath.Glob(filepath.Join(statusDir(), "*.json"))
	var best *statusSnap
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var s statusSnap
		// Snapshots from before they were tagged are taken as the account's.
		if json.Unmarshal(b, &s) == nil && len(s.RateLimits) > 0 && (s.Account == "" || s.Account == who) && (best == nil || s.At > best.At) {
			best = &s
		}
	}
	if asked != nil {
		// Claude Code's own answer; the status line no longer carries limits.
		out["limits"], out["at"] = asked["limits"], asked["at"]
	} else if best != nil {
		lim := map[string]limit{}
		for k, raw := range best.RateLimits {
			if w, ok := limitOf(raw); ok {
				lim[k] = w
			}
		}
		out["limits"], out["at"] = lim, best.At
	}
	if b, err := os.ReadFile(filepath.Join(home, ".claude.json")); err == nil {
		var c struct {
			Account *struct {
				Email   string `json:"emailAddress"`
				Name    string `json:"displayName"`
				Org     string `json:"organizationName"`
				Billing string `json:"billingType"`
				Tier    string `json:"organizationRateLimitTier"`
			} `json:"oauthAccount"`
		}
		if json.Unmarshal(b, &c) == nil && c.Account != nil {
			out["account"] = map[string]string{
				"email": c.Account.Email, "name": c.Account.Name, "org": c.Account.Org, "plan": planName(c.Account.Tier, c.Account.Billing),
			}
		}
	}
	return out
}

// planName turns a rate limit tier like "default_claude_max_20x" into "Max 20x".
func planName(tier, billing string) string {
	t := strings.TrimPrefix(tier, "default_")
	t = strings.TrimPrefix(t, "claude_")
	if t == "" {
		return billing
	}
	w := strings.Split(t, "_")
	for i := range w {
		if w[i] != "" && w[i][0] >= 'a' && w[i][0] <= 'z' {
			w[i] = strings.ToUpper(w[i][:1]) + w[i][1:]
		}
	}
	return strings.Join(w, " ")
}

func cmdUsage() {
	b, _ := json.MarshalIndent(claudeUsage(), "", "  ")
	fmt.Println(string(b))
}

func claudeSettingsPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "settings.json")
}

func statuslineInstalled() bool {
	b, _ := os.ReadFile(claudeSettingsPath())
	return bytes.Contains(b, []byte("macremote\\\" statusline")) || bytes.Contains(b, []byte("macremote statusline"))
}

func statuslineInstall() {
	if msg := statuslineEnsure(); msg != "" {
		fmt.Println(msg)
	} else {
		fmt.Println("the status line is already set up")
	}
}

// stableExe is this binary's path that survives upgrades: Homebrew's opt link
// rather than the versioned Cellar directory.
func stableExe() string {
	exe, err := os.Executable()
	if err != nil {
		return filepath.Join(supportDir(), "macremote")
	}
	exe, _ = filepath.EvalSymlinks(exe)
	if i := strings.Index(exe, "/Cellar/macremote/"); i >= 0 {
		return exe[:i] + "/opt/macremote/bin/macremote"
	}
	return exe
}

// statuslineEnsure adds the status line to Claude Code's user settings,
// unless one is set already (that one stays: the phone then shows no usage).
// It says what it did, or "" when there was nothing to do.
func statuslineEnsure() string {
	p := claudeSettingsPath()
	if _, err := os.Stat(filepath.Dir(p)); err != nil {
		return "" // no Claude Code here
	}
	b, err := os.ReadFile(p)
	if os.IsNotExist(err) {
		b, err = []byte("{}\n"), nil
	}
	if err != nil {
		return fmt.Sprintf("status line: %v", err)
	}
	if statuslineInstalled() {
		return ""
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		return fmt.Sprintf("status line: %s is not plain JSON (%v); usage won't show on the phone", p, err)
	}
	if _, ok := m["statusLine"]; ok {
		return "Claude Code has its own status line; usage won't show on the phone until it runs `macremote statusline`"
	}
	out, err := addStatusLine(b, strconv.Quote(stableExe())+" statusline")
	if err == nil {
		err = os.WriteFile(p, out, 0o644)
	}
	if err != nil {
		return fmt.Sprintf("status line: %v", err)
	}
	return "added Claude Code's status line (usage and context for the phone)"
}

// addStatusLine inserts the setting as text, so the rest of the file keeps its
// order and layout.
func addStatusLine(b []byte, command string) ([]byte, error) {
	cmd, _ := json.Marshal(command)
	entry := `"statusLine": {"type": "command", "command": ` + string(cmd) + `, "padding": 0}`
	i := bytes.IndexByte(b, '{')
	if i < 0 {
		return nil, fmt.Errorf("no JSON object")
	}
	sep := ",\n  "
	if rest := bytes.TrimSpace(b[i+1:]); len(rest) > 0 && rest[0] == '}' {
		sep = "\n"
	}
	out := append(append([]byte{}, b[:i+1]...), []byte("\n  "+entry+sep)...)
	out = append(out, bytes.TrimLeft(b[i+1:], " \t\r\n")...)
	var m map[string]json.RawMessage
	if err := json.Unmarshal(out, &m); err != nil {
		return nil, err
	}
	return out, nil
}
