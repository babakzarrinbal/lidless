package main

import (
	"strings"
	"testing"
)

func TestChatItems(t *testing.T) {
	lines := []string{
		`{"type":"user","message":{"role":"user","content":"fix the build"}}`,
		`{"type":"user","isMeta":true,"message":{"content":"<system-reminder>x</system-reminder>"}}`,
		`{"type":"user","message":{"content":"<command-name>/model</command-name>\n<command-args>opus</command-args>"}}`,
		`{"type":"user","message":{"content":[{"type":"text","text":"<system-reminder>ctx</system-reminder>\nhello"}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hm"}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"Looking **now**."}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/x/a.go","old_string":"a","new_string":"b"}}]}}`,
		`{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":[{"type":"text","text":"ok"}],"is_error":true}]}}`,
		`{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}`,
		`{"type":"attachment"}`,
		`not json`,
	}
	var got []ChatItem
	for _, l := range lines {
		got = append(got, chatItems([]byte(l))...)
	}
	want := []ChatItem{
		{K: "user", Text: "fix the build"},
		{K: "note", Text: "/model opus"},
		{K: "user", Text: "hello"},
		{K: "text", Text: "Looking **now**."},
		{K: "tool", ID: "t1", Name: "Edit", Text: "/x/a.go", Detail: "- a\n+ b"},
		{K: "result", ID: "t1", Text: "ok", Err: true},
		{K: "note", Text: "Conversation compacted"},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d items: %+v", len(got), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("item %d: got %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestCut(t *testing.T) {
	s := strings.Repeat("é", chatText) // 2 bytes each
	c := cut(s)
	if !strings.HasSuffix(c, "more bytes") || !strings.HasPrefix(c, "éé") {
		t.Fatal(c[len(c)-40:])
	}
}
