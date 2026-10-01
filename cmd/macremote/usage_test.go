package main

import (
	"encoding/json"
	"os"
	"path/filepath"
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
		out, err := addStatusLine([]byte(in), `"/A B/macremote" statusline`)
		if err != nil {
			t.Fatal(in, err)
		}
		var m map[string]any
		json.Unmarshal(out, &m)
		sl, _ := m["statusLine"].(map[string]any)
		if sl["command"] != `"/A B/macremote" statusline` || (strings.Contains(in, "model") && m["model"] != "opus") {
			t.Fatalf("%s", out)
		}
	}
}

func TestLineContext(t *testing.T) {
	c := lineContext([]byte(`{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":4470,"cache_read_input_tokens":123412,"output_tokens":3650}}}`))
	if c == nil || c.Tokens != 127884 || c.Model != "claude-opus-5-5" {
		t.Fatalf("%+v", c)
	}
	if lineContext([]byte(`{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":5}}}`)) != nil {
		t.Fatal("a subagent's turn is not the main context")
	}
}

func TestConversationTitleAndCommands(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "s.jsonl")
	os.WriteFile(p, []byte(`{"type":"user","message":{"content":"fix the build\nplease"}}`+"\n"+
		`{"type":"last-prompt","lastPrompt":"and the tests"}`+"\n"), 0o600)
	st, _ := os.Stat(p)
	title, prompt := conversationTitle(p, st.Size())
	if title != "fix the build" || prompt != "and the tests" {
		t.Fatal(title, prompt)
	}
	os.WriteFile(p, []byte(`{"type":"ai-title","aiTitle":"Build fix"}`+"\n"), 0o600)
	st, _ = os.Stat(p)
	if title, _ := conversationTitle(p, st.Size()); title != "Build fix" {
		t.Fatal(title)
	}

	os.MkdirAll(filepath.Join(d, ".claude", "commands", "git"), 0o700)
	os.MkdirAll(filepath.Join(d, ".claude", "skills", "ship"), 0o700)
	os.WriteFile(filepath.Join(d, ".claude", "commands", "git", "pr.md"), []byte("---\ndescription: Open a PR\n---\nbody"), 0o600)
	os.WriteFile(filepath.Join(d, ".claude", "skills", "ship", "SKILL.md"), []byte("---\nname: ship\ndescription: \"Release it\"\n---\n"), 0o600)
	got := map[string]SlashCommand{}
	for _, c := range chatCommands(d, "claude") {
		got[c.Name] = c
	}
	if got["git:pr"].Desc != "Open a PR" || got["ship"].Desc != "Release it" || got["ship"].Src != "skill" || got["compact"].Src != "built-in" {
		t.Fatalf("%+v %+v %+v", got["git:pr"], got["ship"], got["compact"])
	}
}
