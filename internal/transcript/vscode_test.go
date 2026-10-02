package transcript

import (
	"encoding/json"
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

	l := VSCodeConversations(nil, 10, func(c *Conversation) bool { return c.Dir == "/w/my app" })
	if len(l) != 1 || l[0].ID != id || l[0].Tool != "vscode" || l[0].Title != "Build fix" || l[0].Prompt != "thanks" || l[0].Running {
		t.Fatalf("list: %+v", l)
	}
	shared := func(string) bool { return true }
	m, err := vscodeState(filepath.Join(ws, "chatSessions", id+".jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	items := vscodeItems(m)
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
	h, err := VSCodeHandoff(id, shared)
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
	if _, err := VSCodeHandoff(id, func(string) bool { return false }); err == nil {
		t.Error("a chat outside the shared folders was handed off")
	}

	// Moved here: the terminal Copilot carries it on in has it.
	terms := []*Terminal{{ID: 4, Run: "copilot -i " + h["prompt"].(string)}}
	if l := VSCodeConversations(terms, 10, nil); len(l) != 1 || !l[0].Running || l[0].Term != 4 {
		t.Fatalf("carried: %+v", l)
	}

	// The Copilot session it started stands in for the chat.
	cp := filepath.Join(home, ".copilot", "session-state", "7bc294a5-fb02-4f4d-9800-f06e9d77dde1")
	os.MkdirAll(cp, 0o755)
	os.WriteFile(filepath.Join(cp, "workspace.yaml"), []byte("cwd: /w/my app\n"), 0o644)
	os.WriteFile(filepath.Join(cp, "events.jsonl"), []byte(`{"type":"user.message","data":{"content":`+quote(h["prompt"].(string))+`}}`+"\n"), 0o644)
	all := WithVSCode(CopilotConversations(nil, 10, nil), nil, 10, nil)
	if len(all) != 1 || all[0].Tool != "copilot" || all[0].From != id || all[0].Title != "Build fix" || all[0].Prompt != "" {
		t.Fatalf("moved: %+v", all)
	}

	// Its chat view: the VS Code chat's history, the line where it moved, then
	// the session, without the chat in the session itself.
	if strings.Contains(h["prompt"].(string), "Looking at it") {
		t.Errorf("the prompt carries the chat: %v", h["prompt"])
	}
	events := filepath.Join(cp, "events.jsonl")
	f, _ := os.OpenFile(events, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"type":"assistant.message","data":{"content":"We left off at the build."}}` + "\n")
	f.Close()
	copilotPath = func(int) string { return events }
	defer func() { copilotPath = copilotTranscript }()
	term := &Terminal{ID: 4, Kind: "copilot"}
	r, err := ChatRead(term, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	got := r["items"].([]ChatItem)
	if len(got) != 2 || got[0] != (ChatItem{K: "note", Text: movedNote}) || got[1].Text != "We left off at the build." {
		t.Fatalf("read: %+v", got)
	}
	name, start := r["path"].(string), r["start"].(int64)
	if start <= 0 {
		t.Fatalf("no history before the session: start %d", start)
	}
	if r2, _ := ChatRead(term, r["next"].(int64), name); r2["reset"] != false || len(r2["items"].([]ChatItem)) != 0 {
		t.Fatalf("read on: %+v", r2)
	}
	o, err := ChatOlder(term, start, name)
	if err != nil {
		t.Fatal(err)
	}
	older := o["items"].([]ChatItem)
	if o["start"].(int64) != 0 || len(older) != len(want) {
		t.Fatalf("older: %+v", o)
	}
	for i := range want {
		if older[i] != want[i] {
			t.Errorf("older %d: %+v, want %+v", i, older[i], want[i])
		}
	}

	// Moved by an older agent: no snapshot yet, made from the chat.
	os.Remove(filepath.Join(vscodeCache(), id+".items.jsonl"))
	if r, _ := ChatRead(term, 0, ""); r["start"].(int64) != start {
		t.Fatalf("snapshot again: %+v", r)
	}
}

func TestVSCodeEmptyWindow(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	d := filepath.Join(home, "Library", "Application Support", "Code", "User", "globalStorage", "emptyWindowChatSessions")
	os.MkdirAll(d, 0o755)
	id := "0fb1b9c7-9892-48c1-996a-b6de7726603c"
	os.WriteFile(filepath.Join(d, id+".json"), []byte(`{"requests":[{"message":{"text":"hi"},"response":[]}]}`), 0o644)
	if l := VSCodeConversations(nil, 10, nil); len(l) != 1 || l[0].Dir != home || l[0].Title != "hi" {
		t.Fatalf("list: %+v", l)
	}
}

func quote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
