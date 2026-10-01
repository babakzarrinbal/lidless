package main

// Plan limits, asked of the CLIs that are already signed in on this Mac:
// Claude Code answers a `get_usage` control request (the numbers its /usage
// screen shows; no model call), and the GitHub CLI reads Copilot's monthly
// premium request quota. No credential is read here: each tool uses its own.

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// findTool finds a CLI the way a login shell would, without starting one:
// the agent runs under launchd with a bare PATH.
func findTool(name string) string {
	home, _ := os.UserHomeDir()
	for _, d := range []string{
		filepath.Join(home, ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin",
		filepath.Join(home, ".npm-global", "bin"), filepath.Join(home, ".bun", "bin"),
	} {
		p := filepath.Join(d, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p
		}
	}
	p, _ := exec.LookPath(name)
	return p
}

type cached struct {
	mu  sync.Mutex
	at  time.Time
	val map[string]any
}

// get returns the value, asking again when it is older than every.
func (c *cached) get(every time.Duration, ask func() map[string]any) map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.val == nil || time.Since(c.at) > every {
		if v := ask(); v != nil || c.val == nil || time.Since(c.at) > 15*time.Minute {
			c.val, c.at = v, time.Now()
		}
	}
	return c.val
}

var claudeLimitsCache, copilotQuotaCache cached

// claudeLimits is the signed-in account's plan limits, as {"limits": {key:
// limit}, "at": unix}, or nil when Claude Code can't tell (an API key, an
// older version, not signed in).
func claudeLimits() map[string]any {
	return claudeLimitsCache.get(time.Minute, askClaudeLimits)
}

func askClaudeLimits() map[string]any {
	bin := findTool("claude")
	if bin == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	// No user settings: their hooks and status line stay out of it.
	cmd := exec.CommandContext(ctx, bin, "-p", "--setting-sources", "", "--no-session-persistence",
		"--input-format", "stream-json", "--output-format", "stream-json", "--verbose")
	cmd.Dir = os.TempDir()
	cmd.Env = shellEnv()
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil
	}
	if cmd.Start() != nil {
		return nil
	}
	defer func() { in.Close(); cmd.Process.Kill(); cmd.Wait() }()
	in.Write([]byte(`{"type":"control_request","request_id":"macremote-usage","request":{"subtype":"get_usage"}}` + "\n"))
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 64<<10), 8<<20)
	for sc.Scan() {
		var m struct {
			Type     string `json:"type"`
			Response struct {
				ID       string          `json:"request_id"`
				Response json.RawMessage `json:"response"`
			} `json:"response"`
		}
		if json.Unmarshal(sc.Bytes(), &m) != nil || m.Type != "control_response" || m.Response.ID != "macremote-usage" {
			continue
		}
		return parseClaudeLimits(m.Response.Response)
	}
	return nil
}

type usageWindow struct {
	Util   *float64 `json:"utilization"`
	Resets string   `json:"resets_at"`
}

func (w usageWindow) limit() (limit, bool) {
	if w.Util == nil {
		return limit{}, false
	}
	var at int64
	if t, err := time.Parse(time.RFC3339Nano, w.Resets); err == nil {
		at = t.Unix()
	}
	return limit{*w.Util, at}, true
}

func parseClaudeLimits(raw []byte) map[string]any {
	var r struct {
		Available bool                       `json:"rate_limits_available"`
		Limits    map[string]json.RawMessage `json:"rate_limits"`
	}
	if json.Unmarshal(raw, &r) != nil || !r.Available || r.Limits == nil {
		return nil
	}
	lim := map[string]limit{}
	for k, v := range r.Limits {
		// five_hour, seven_day, seven_day_opus…; the rest are flags and lists.
		if k != "five_hour" && !strings.HasPrefix(k, "seven_day") {
			continue
		}
		var w usageWindow
		if json.Unmarshal(v, &w) == nil {
			if l, ok := w.limit(); ok {
				lim[k] = l
			}
		}
	}
	// Weekly limits of one model (e.g. Fable), labelled by the server.
	var scoped []struct {
		Name string `json:"display_name"`
		usageWindow
	}
	json.Unmarshal(r.Limits["model_scoped"], &scoped)
	for _, s := range scoped {
		k := "seven_day_" + strings.ToLower(strings.ReplaceAll(s.Name, " ", "_"))
		if l, ok := s.limit(); ok && s.Name != "" {
			if _, dup := lim[k]; !dup {
				lim[k] = l
			}
		}
	}
	if len(lim) == 0 {
		return nil
	}
	return map[string]any{"limits": lim, "at": time.Now().Unix()}
}

// copilotQuota is Copilot's monthly premium requests, through the GitHub CLI's
// own sign-in: {"login", "plan", "limits": {"premium": limit}, "used", "of",
// "unlimited", "ended", "at"}, or nil without gh or Copilot.
func copilotQuota() map[string]any {
	return copilotQuotaCache.get(5*time.Minute, askCopilotQuota)
}

func askCopilotQuota() map[string]any {
	bin := findTool("gh")
	if bin == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "api", "/copilot_internal/user")
	cmd.Env = shellEnv()
	b, err := cmd.Output()
	if err != nil {
		return nil
	}
	return parseCopilotQuota(b, time.Now())
}

func parseCopilotQuota(b []byte, now time.Time) map[string]any {
	var u struct {
		Login  string `json:"login"`
		Plan   string `json:"copilot_plan"`
		SKU    string `json:"access_type_sku"`
		Resets string `json:"quota_reset_date_utc"`
		Day    string `json:"quota_reset_date"`
		Quotas map[string]struct {
			Entitlement float64 `json:"entitlement"`
			Remaining   float64 `json:"remaining"`
			PctLeft     float64 `json:"percent_remaining"`
			Unlimited   bool    `json:"unlimited"`
		} `json:"quota_snapshots"`
	}
	if json.Unmarshal(b, &u) != nil || u.Login == "" {
		return nil
	}
	out := map[string]any{"login": u.Login, "plan": u.Plan, "at": now.Unix(), "ended": strings.Contains(u.SKU, "ended")}
	var resets int64
	if t, err := time.Parse(time.RFC3339Nano, u.Resets); err == nil {
		resets = t.Unix()
	} else if t, err := time.Parse("2006-01-02", u.Day); err == nil {
		resets = t.Unix()
	}
	if q, ok := u.Quotas["premium_interactions"]; ok {
		if q.Unlimited {
			out["unlimited"] = true
		} else {
			out["limits"] = map[string]limit{"premium": {100 - q.PctLeft, resets}}
			out["used"], out["of"] = q.Entitlement-q.Remaining, q.Entitlement
		}
	}
	return out
}
