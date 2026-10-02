package usage

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestStatusLine(t *testing.T) {
	var s statusSnap
	json.Unmarshal([]byte(`{"session_id":"abc-12345678","model":{"display_name":"Opus 5.5"},
		"context_window":{"context_window_size":1000000,"used_percentage":12,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":4470,"cache_read_input_tokens":123412}},
		"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}`), &s)
	if got := statusLine(s); got != "Opus 5.5 · ctx 127k/1.0M · 5h 24% · 7d 41%" {
		t.Fatal(got)
	}
	if got := planName("default_claude_max_20x", "stripe"); got != "Max 20x" {
		t.Fatal(got)
	}
}

func TestAddStatusLine(t *testing.T) {
	for _, in := range []string{"{}\n", "{\n  \"model\": \"opus\",\n  \"hooks\": {}\n}\n"} {
		out, err := addStatusLine([]byte(in), `"/A B/uniai" statusline`)
		if err != nil {
			t.Fatal(in, err)
		}
		var m map[string]any
		json.Unmarshal(out, &m)
		sl, _ := m["statusLine"].(map[string]any)
		if sl["command"] != `"/A B/uniai" statusline` || (strings.Contains(in, "model") && m["model"] != "opus") {
			t.Fatalf("%s", out)
		}
	}
}
