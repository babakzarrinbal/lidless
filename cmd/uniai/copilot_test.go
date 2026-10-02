package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const copilotEvents = `{"type":"session.start","data":{"sessionId":"x"}}
{"type":"user.message","data":{"content":"fix the build"}}
{"type":"user.message","data":{"content":"<reminder>","source":"system"}}
{"type":"assistant.message","data":{"content":"","toolRequests":[{"toolCallId":"t1","name":"bash"}]}}
{"type":"tool.execution_start","data":{"toolCallId":"i1","toolName":"report_intent","arguments":{"intent":"Fixing"}}}
{"type":"tool.execution_start","data":{"toolCallId":"t1","toolName":"bash","arguments":{"command":"make\nmake test","description":"Build it"}}}
{"type":"tool.execution_complete","data":{"toolCallId":"t1","success":true,"result":{"content":"ok"}}}
{"type":"tool.execution_start","data":{"toolCallId":"t2","toolName":"view","arguments":{"path":"/tmp/a.go"}}}
{"type":"tool.execution_complete","data":{"toolCallId":"t2","success":false,"error":{"message":"no such file"}}}
{"type":"tool.execution_start","data":{"toolCallId":"s1","toolName":"bash","parentToolCallId":"t9","arguments":{"command":"ls"}}}
{"type":"assistant.message","data":{"content":"Done: the build passes."}}
{"type":"session.title_changed","data":{"title":"Fix the build"}}
{"type":"user.message","data":{"content":"thanks"}}
`

func TestCopilotItems(t *testing.T) {
	var got []ChatItem
	for _, l := range strings.Split(copilotEvents, "\n") {
		got = append(got, copilotItems([]byte(l))...)
	}
	want := []ChatItem{
		{K: "user", Text: "fix the build"},
		{K: "tool", ID: "t1", Name: "Bash", Text: "Build it", Detail: "make\nmake test"},
		{K: "result", ID: "t1", Text: "ok"},
		{K: "tool", ID: "t2", Name: "Read", Text: "/tmp/a.go"},
		{K: "result", ID: "t2", Text: "no such file", Err: true},
		{K: "text", Text: "Done: the build passes."},
		{K: "user", Text: "thanks"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got  %+v\nwant %+v", got, want)
	}
}

func TestCopilotConversations(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	id := "7bc294a5-fb02-4f4d-9800-f06e9d77dde1"
	d := filepath.Join(home, ".copilot", "session-state", id)
	os.MkdirAll(d, 0o755)
	os.WriteFile(filepath.Join(d, "workspace.yaml"), []byte("id: "+id+"\ncwd: /work/app\n"), 0o644)
	os.WriteFile(filepath.Join(d, "events.jsonl"), []byte(copilotEvents), 0o644)
	// One that never got a message: not listed.
	e := filepath.Join(home, ".copilot", "session-state", "4ce35822-2ead-48ed-9c00-e3da87dc8638")
	os.MkdirAll(e, 0o755)
	os.WriteFile(filepath.Join(e, "workspace.yaml"), []byte("cwd: /work/app\n"), 0o644)

	l := copilotConversations(nil, 10, func(c *Conversation) bool { return c.Dir == "/work/app" })
	if len(l) != 1 || l[0].ID != id || l[0].Tool != "copilot" || l[0].Title != "Fix the build" || l[0].Prompt != "thanks" || l[0].Running {
		t.Fatalf("got %+v", l)
	}
	if l := copilotConversations(nil, 10, func(c *Conversation) bool { return c.Dir == "/elsewhere" }); len(l) != 0 {
		t.Fatalf("other folder: got %+v", l)
	}
}

func TestCopilotCommand(t *testing.T) {
	home := t.TempDir()
	shim := filepath.Join(home, "Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilotCli/copilot")
	os.MkdirAll(filepath.Dir(shim), 0o755)
	os.WriteFile(shim, []byte("#!/bin/sh\n"), 0o755)
	local, brew := filepath.Join(home, "local"), filepath.Join(home, "brew dir")
	os.MkdirAll(local, 0o755)
	os.MkdirAll(brew, 0o755)
	os.Symlink(shim, filepath.Join(local, "copilot"))
	// A stand-in login shell whose PATH has the shim's symlink first.
	sh := filepath.Join(home, "sh")
	os.WriteFile(sh, []byte("#!/bin/sh\nshift 2\nPATH=\""+local+":"+brew+":/usr/bin:/bin\" exec /bin/sh -c \"$@\"\n"), 0o755)

	if _, err := copilotCommand(sh, "copilot --continue"); err == nil || !strings.Contains(err.Error(), "shim") {
		t.Fatalf("only the shim: got %v", err)
	}
	os.WriteFile(filepath.Join(brew, "copilot"), []byte("#!/bin/sh\n"), 0o755)
	got, err := copilotCommand(sh, "copilot --resume abc")
	if want := "'" + filepath.Join(brew, "copilot") + "' --resume abc"; err != nil || got != want {
		t.Fatalf("got %q %v, want %q", got, err, want)
	}
	if got, _ := copilotCommand(sh, "claude --continue"); got != "claude --continue" {
		t.Fatalf("not copilot: got %q", got)
	}
}
