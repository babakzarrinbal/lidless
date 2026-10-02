package transcript

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestChatRecentAcrossFolders(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	write := func(dir, id, text string, age time.Duration) {
		p := filepath.Join(ClaudeProjectDir(dir), id+".jsonl")
		os.MkdirAll(filepath.Dir(p), 0o700)
		os.WriteFile(p, []byte(`{"type":"user","cwd":"`+dir+`","message":{"role":"user","content":"`+text+`"}}`+"\n"), 0o600)
		at := time.Now().Add(-age)
		os.Chtimes(p, at, at)
	}
	write("/w/a.b", "s1", "older", 2*time.Hour)
	write("/w/c", "s2", "newest", time.Minute)
	write("/secret", "s3", "hidden", 0)
	got := ChatRecent(nil, 10, func(dir string) bool { return strings.HasPrefix(dir, "/w/") })
	if len(got) != 2 || got[0].ID != "s2" || got[0].Dir != "/w/c" || got[1].Dir != "/w/a.b" || got[0].Title != "newest" {
		t.Fatalf("%+v", got)
	}
	if one := ChatRecent(nil, 1, func(string) bool { return true }); len(one) != 1 || one[0].ID != "s3" {
		t.Fatalf("%+v", one)
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
	for _, c := range ChatCommands(d, "claude") {
		got[c.Name] = c
	}
	if got["git:pr"].Desc != "Open a PR" || got["ship"].Desc != "Release it" || got["ship"].Src != "skill" || got["compact"].Src != "built-in" {
		t.Fatalf("%+v %+v %+v", got["git:pr"], got["ship"], got["compact"])
	}
}
