package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVSCodeChat(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	ws := filepath.Join(home, "Library", "Application Support", "Code", "User", "workspaceStorage", "abc")
	os.MkdirAll(filepath.Join(ws, "chatSessions"), 0o755)
	os.WriteFile(filepath.Join(ws, "workspace.json"), []byte(`{"folder":"file:///w/my%20app"}`), 0o644)
	log := `{"kind":0,"v":{"version":3,"requests":[],"customTitle":null}}
{"kind":2,"k":["requests"],"v":[{"message":{"text":"fix the build"},"response":[]}]}
{"kind":2,"k":["requests",0,"response"],"v":[{"value":"Looking "},{"value":"at it."}]}
{"kind":2,"k":["requests",0,"response"],"v":[{"kind":"toolInvocationSerialized","toolId":"copilot_readFile","toolCallId":"t1","isComplete":true,"pastTenseMessage":{"value":"Read [](file:///w/my%20app/a.go)"}}]}
{"kind":2,"k":["requests",0,"response"],"v":[{"kind":"toolInvocationSerialized","toolId":"run_in_terminal","toolCallId":"t2","isComplete":true,"toolSpecificData":{"commandLine":{"original":"go build"},"terminalCommandOutput":{"text":"\u001b[31mfail\u001b[0m\r\n"},"terminalCommandState":{"exitCode":1}}},{"kind":"thinking","value":"hmm"},{"value":"Done."}]}
{"kind":2,"k":["requests"],"v":[{"message":{"text":"dropped"},"response":[]}],"i":1}
{"kind":2,"k":["requests"],"v":[{"message":{"text":"thanks"},"response":[]}],"i":1}
{"kind":1,"k":["customTitle"],"v":"Build fix"}
{"kind":1,"k":["requests",1,"result"],"v":{"errorDetails":{"message":"network error"}}}
`
	id := "0fb1b9c7-9892-48c1-996a-b6de7726603c"
	os.WriteFile(filepath.Join(ws, "chatSessions", id+".jsonl"), []byte(log), 0o644)
	os.WriteFile(filepath.Join(ws, "chatSessions", "11111111-0000-0000-0000-000000000000.jsonl"),
		[]byte(`{"kind":0,"v":{"requests":[]}}`+"\n"), 0o644) // nothing said: not listed

	l := vscodeConversations(10, func(c *Conversation) bool { return c.Dir == "/w/my app" })
	if len(l) != 1 || l[0].ID != id || l[0].Tool != "vscode" || l[0].Title != "Build fix" || l[0].Prompt != "thanks" {
		t.Fatalf("list: %+v", l)
	}
	shared := func(string) bool { return true }
	r, err := vscodeTranscript(id, 0, 0, shared)
	if err != nil {
		t.Fatal(err)
	}
	items := r["items"].([]ChatItem)
	want := []ChatItem{
		{K: "user", Text: "fix the build"},
		{K: "text", Text: "Looking at it."},
		{K: "tool", ID: "t1", Name: "Read", Text: "Read /w/my app/a.go"},
		{K: "result", ID: "t1"},
		{K: "tool", ID: "t2", Name: "Bash", Text: "go build", Detail: "go build"},
		{K: "result", ID: "t2", Text: "fail", Err: true},
		{K: "text", Text: "Done."},
		{K: "user", Text: "thanks"},
		{K: "note", Text: "network error"},
	}
	if len(items) != len(want) {
		t.Fatalf("items: %+v", items)
	}
	for i := range want {
		if items[i] != want[i] {
			t.Errorf("item %d: %+v, want %+v", i, items[i], want[i])
		}
	}
	if again, _ := vscodeTranscript(id, r["size"].(int64), r["mtime"].(int64), shared); again["same"] != true {
		t.Errorf("unchanged file read again: %v", again)
	}
	h, err := vscodeHandoff(id, shared)
	if err != nil {
		t.Fatal(err)
	}
	md, _ := os.ReadFile(h["path"].(string))
	for _, w := range []string{"# Build fix", "## Me\n\nfix the build", "## Copilot\n\nLooking at it.", "- Bash: go build\n  (failed: fail)", "> network error"} {
		if !strings.Contains(string(md), w) {
			t.Errorf("handoff lacks %q:\n%s", w, md)
		}
	}
	if !strings.Contains(h["prompt"].(string), h["path"].(string)) {
		t.Errorf("prompt: %v", h["prompt"])
	}
	if _, err := vscodeTranscript(id, 0, 0, func(string) bool { return false }); err == nil {
		t.Error("a chat outside the shared folders was read")
	}
}

func TestVSCodeMirror(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	id := "0fb1b9c7-9892-48c1-996a-b6de7726603c"
	path := filepath.Join(home, id+".jsonl")
	// VS Code's last line may lack its newline yet.
	os.WriteFile(path, []byte(`{"kind":0,"v":{"requests":[{"requestId":"request_1","modelId":"copilot/auto","message":{"text":"fix it"},"response":[{"value":"On it."}]}]}}`), 0o644)

	items := []ChatItem{
		{K: "user", Text: "This carries on a conversation … " + vscodeCache() + "/" + id + ".md, then …"},
		{K: "text", Text: "We were fixing the build."},
		{K: "user", Text: "go on"},
		{K: "tool", ID: "a", Name: "Bash", Text: "go test"},
		{K: "result", ID: "a", Text: "fail", Err: true},
		{K: "text", Text: "Fixed."},
	}
	turns := vscodeTurns(items, id, "copilot")
	if len(turns) != 2 || turns[0].Prompt != "Continue on all devices" || !strings.Contains(turns[0].Answer, "(Copilot CLI)") ||
		!strings.HasSuffix(turns[0].Answer, "We were fixing the build.") {
		t.Fatalf("turns: %+v", turns)
	}
	if want := "- *Bash* `go test` (failed: `fail`)\n\nFixed."; turns[1] != (vscodeTurn{"go on", want}) {
		t.Fatalf("turn 2: %+v", turns[1])
	}

	if err := vscodeWriteTurns(path, id, 7, turns); err != nil {
		t.Fatal(err)
	}
	m, err := vscodeState(path)
	if err != nil {
		t.Fatal(err)
	}
	reqs := vscodeRequests(m)
	if len(reqs) != 3 || reqs[2]["requestId"] != "request_uniai-7-1" || vscodeTyped(reqs[2]) != "go on" ||
		vscodeAnswer(reqs[2]) != turns[1].Answer || reqs[2]["modelId"] != "copilot/auto" {
		t.Fatalf("requests: %+v", reqs)
	}
	if _, err := os.Stat(filepath.Join(vscodeCache(), id+".jsonl.bak")); err != nil {
		t.Error("no backup:", err)
	}

	st, _ := os.Stat(path)
	if err := vscodeWriteTurns(path, id, 7, turns); err != nil {
		t.Fatal(err)
	}
	if st2, _ := os.Stat(path); st2.Size() != st.Size() {
		t.Error("the same turns were written again")
	}
	turns[1].Answer += "\n\nAll green."
	vscodeWriteTurns(path, id, 7, turns)
	m, _ = vscodeState(path)
	if reqs = vscodeRequests(m); len(reqs) != 3 || vscodeAnswer(reqs[2]) != turns[1].Answer {
		t.Fatalf("answer not updated: %+v", reqs)
	}
}
