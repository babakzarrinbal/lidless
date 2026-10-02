package transcript

import (
	"strconv"
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
		`{"type":"queue-operation","operation":"enqueue","content":"also this"}`,
		`{"type":"queue-operation","operation":"enqueue","content":"<task-notification>x</task-notification>"}`,
		`{"type":"queue-operation","operation":"remove","content":"also this","reason":"absorbed_mid_turn"}`,
		`{"type":"attachment","attachment":{"type":"queued_command","prompt":"also this","origin":{"kind":"human"}}}`,
		`{"type":"attachment","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"and that"}],"origin":{"kind":"human"}}}`,
		`{"type":"attachment","attachment":{"type":"queued_command","prompt":"bg","origin":{"kind":"task"}}}`,
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
		{K: "queued", Text: "also this"},
		{K: "unqueue", Text: "also this"},
		{K: "user", Text: "also this"},
		{K: "user", Text: "and that"},
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

func TestOlderItems(t *testing.T) {
	var b strings.Builder
	for i := range 3000 {
		b.WriteString(`{"type":"user","message":{"role":"user","content":"message ` + strconv.Itoa(i) + `"}}` + "\n")
	}
	f := strings.NewReader(b.String())
	// Back from the end, page by page, to the first message, each one once.
	var got []string
	for before := int64(b.Len()); before > 0; {
		items, start, err := olderItems(f, before, chatItems)
		if err != nil || start >= before {
			t.Fatalf("before %d: start %d, %v", before, start, err)
		}
		page := []string{}
		for _, it := range items {
			page = append(page, it.Text)
		}
		got, before = append(page, got...), start
	}
	if len(got) != 3000 || got[0] != "message 0" || got[2999] != "message 2999" {
		t.Fatalf("%d items, %q … %q", len(got), got[0], got[len(got)-1])
	}
	// A line longer than a page is skipped, and what is before it still comes.
	long := `{"type":"user","message":{"content":"first"}}` + "\n" + `{"x":"` + strings.Repeat("y", chatPage+100) + `"}` + "\n"
	r := strings.NewReader(long)
	var texts []string
	for before := int64(len(long)); before > 0; {
		items, start, _ := olderItems(r, before, chatItems)
		for _, it := range items {
			texts = append(texts, it.Text)
		}
		before = start
	}
	if len(texts) != 1 || texts[0] != "first" {
		t.Fatalf("got %q", texts)
	}
}
