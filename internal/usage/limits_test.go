package usage

import (
	"testing"
	"time"
)

func TestParseClaudeLimits(t *testing.T) {
	got := parseClaudeLimits([]byte(`{"subscription_type":"max","rate_limits_available":true,"rate_limits":{
		"five_hour":{"utilization":4,"resets_at":"2026-10-01T16:39:59.608118+00:00"},
		"seven_day":{"utilization":47,"resets_at":"2026-10-03T08:59:59.608145+00:00"},
		"seven_day_opus":null,"extra_usage":{"is_enabled":false},
		"limits":[{"kind":"session","percent":4}],
		"model_scoped":[{"display_name":"Fable","utilization":0,"resets_at":"2026-10-03T09:00:00+00:00"}]}}`))
	lim := got["limits"].(map[string]limit)
	if len(lim) != 3 || lim["five_hour"].Pct != 4 || lim["seven_day"].Pct != 47 || lim["seven_day_fable"].Pct != 0 {
		t.Fatalf("%v", lim)
	}
	if lim["five_hour"].Resets != time.Date(2026, 10, 1, 16, 39, 59, 0, time.UTC).Unix() {
		t.Fatalf("resets %v", lim["five_hour"].Resets)
	}
	if parseClaudeLimits([]byte(`{"rate_limits_available":false,"rate_limits":null}`)) != nil {
		t.Fatal("an API key has no limits")
	}
}

func TestParseCopilotQuota(t *testing.T) {
	now := time.Unix(1_790_000_000, 0)
	got := parseCopilotQuota([]byte(`{"login":"me","copilot_plan":"individual","access_type_sku":"monthly_subscriber",
		"quota_reset_date":"2026-11-01","quota_reset_date_utc":"2026-11-01T00:00:00.000Z",
		"quota_snapshots":{"chat":{"unlimited":true},"premium_interactions":{"entitlement":300,"remaining":210,"percent_remaining":70,"unlimited":false}}}`), now)
	lim := got["limits"].(map[string]limit)
	if lim["premium"].Pct != 30 || got["used"] != 90.0 || got["of"] != 300.0 || got["ended"] != false {
		t.Fatalf("%v", got)
	}
	if lim["premium"].Resets != time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC).Unix() {
		t.Fatalf("resets %v", lim["premium"].Resets)
	}
	ended := parseCopilotQuota([]byte(`{"login":"me","copilot_plan":"individual","access_type_sku":"subscription_ended","quota_snapshots":null}`), now)
	if ended["ended"] != true || ended["limits"] != nil {
		t.Fatalf("%v", ended)
	}
}
