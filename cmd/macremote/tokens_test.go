package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func answer(id, ts string, in, out, cr, cw int64) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":%q,"message":{"id":%q,"model":"claude-opus-5-5","usage":{"input_tokens":%d,"output_tokens":%d,"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d}}}`+"\n", ts, id, in, out, cr, cw)
}

type tokenFixture struct {
	t                     *testing.T
	home, claude, copilot string
	l                     *ledger
}

func newTokenFixture(t *testing.T) *tokenFixture {
	home := t.TempDir()
	f := &tokenFixture{t: t, home: home, claude: filepath.Join(home, ".claude"), copilot: filepath.Join(home, ".copilot")}
	f.l = newLedger(f.claude, f.copilot, filepath.Join(home, "support"))
	f.signIn("a@x.com")
	return f
}

func (f *tokenFixture) signIn(email string) {
	os.WriteFile(filepath.Join(f.home, ".claude.json"), []byte(`{"oauthAccount":{"emailAddress":"`+email+`"}}`), 0o600)
}

func (f *tokenFixture) write(rel, text string, appendTo bool) string {
	p := filepath.Join(f.claude, "projects", rel)
	os.MkdirAll(filepath.Dir(p), 0o700)
	flag := os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	if appendTo {
		flag = os.O_CREATE | os.O_WRONLY | os.O_APPEND
	}
	h, err := os.OpenFile(p, flag, 0o600)
	if err != nil {
		f.t.Fatal(err)
	}
	h.WriteString(text)
	h.Close()
	return p
}

func (f *tokenFixture) totals() map[string]int64 {
	f.l.at = time.Time{}
	out := map[string]int64{}
	for _, a := range f.l.tokenTotals() {
		out[a["tool"].(string)+"|"+a["account"].(string)] = a["total"].(int64)
	}
	return out
}

func TestTokensCountOnceAndPerChat(t *testing.T) {
	f := newTokenFixture(t)
	// Two lines per answer (one per content block), and a half-written line.
	main := f.write("-p/s1.jsonl",
		answer("m1", "2026-09-01T10:00:00Z", 10, 20, 300, 40)+
			answer("m1", "2026-09-01T10:00:00Z", 10, 20, 300, 40)+
			`{"type":"user","message":{"content":"hi"}}`+"\n"+
			answer("m2", "2026-09-01T10:01:00Z", 1, 2, 3, 4)+
			`{"type":"assistant","message":{"id":"m3"`, false)
	os.Chtimes(main, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour))
	f.write("-p/s1/subagents/agent-1.jsonl", answer("m9", "2026-09-01T10:02:00Z", 100, 0, 0, 0), false)
	// A resumed copy of s1 repeats its answers: they count once, for s1.
	f.write("-p/s2.jsonl", answer("m1", "2026-09-01T10:00:00Z", 10, 20, 300, 40)+answer("m4", "2026-09-02T10:00:00Z", 1000, 0, 0, 0), false)

	if got := f.totals()["claude|a@x.com"]; got != 370+10+100+1000 {
		t.Fatalf("total %d", got)
	}
	if got := f.l.chatTokens(main)["total"]; got != int64(370+10+100) {
		t.Fatalf("s1 with its subagent: %v", got)
	}
	if got := f.l.chatTokens(filepath.Join(f.claude, "projects", "-p", "s2.jsonl"))["total"]; got != int64(1000) {
		t.Fatalf("s2: %v", got)
	}

	// The rest of the half line arrives; nothing is read twice.
	f.write("-p/s1.jsonl", `,"model":"m","usage":{"input_tokens":5}}}`+"\n", true)
	if got := f.totals()["claude|a@x.com"]; got != 1480+5 {
		t.Fatalf("after append %d", got)
	}

	// Claude deletes old transcripts; what was counted stays, and a fresh
	// ledger (an agent restart) loads it back without counting again.
	os.RemoveAll(filepath.Join(f.claude, "projects", "-p", "s2.jsonl"))
	again := newLedger(f.claude, f.copilot, f.l.dir)
	f.l = again
	if got := f.totals()["claude|a@x.com"]; got != 1485 {
		t.Fatalf("after restart %d", got)
	}
}

func TestTokensFollowTheAccount(t *testing.T) {
	f := newTokenFixture(t)
	f.write("-p/s1.jsonl", answer("m1", "2020-01-01T00:00:00Z", 7, 0, 0, 0), false)
	f.totals() // a@x.com signed in from now on; older answers are theirs too
	f.signIn("b@y.com")
	f.totals()
	f.write("-p/s1.jsonl", answer("m2", time.Now().Add(time.Minute).UTC().Format(time.RFC3339), 9, 0, 0, 0), true)
	got := f.totals()
	if got["claude|a@x.com"] != 7 || got["claude|b@y.com"] != 9 {
		t.Fatalf("%v", got)
	}
	used := f.l.chatTokens(filepath.Join(f.claude, "projects", "-p", "s1.jsonl"))
	if accts := used["accounts"].([]string); len(accts) != 2 || accts[0] != "a@x.com" || accts[1] != "b@y.com" {
		t.Fatalf("accounts %v", accts)
	}
	// The signed-in account comes first.
	if first := f.l.tokenTotals()[0]["account"]; first != "b@y.com" {
		t.Fatalf("first %v", first)
	}
}

func TestTokensReset(t *testing.T) {
	f := newTokenFixture(t)
	f.write("-p/s1.jsonl", answer("m1", "2026-09-01T10:00:00Z", 50, 0, 0, 0), false)
	f.totals()
	if !f.l.reset("claude", "a@x.com") || f.l.reset("claude", "nobody") {
		t.Fatal("reset")
	}
	f.write("-p/s1.jsonl", answer("m2", "2026-09-01T10:00:00Z", 8, 0, 0, 0), true)
	f.l.at = time.Time{}
	a := f.l.tokenTotals()[0]
	if a["total"] != int64(8) || a["all"] != int64(58) || a["reset"] != true {
		t.Fatalf("%v", a)
	}
}

func TestTokensCopilot(t *testing.T) {
	f := newTokenFixture(t)
	p := filepath.Join(f.copilot, "session-state", "abc", "events.jsonl")
	os.MkdirAll(filepath.Dir(p), 0o700)
	shutdown := func(in, out, cr int64) string {
		return fmt.Sprintf(`{"type":"session.shutdown","timestamp":"2026-09-01T10:00:00Z","data":{"modelMetrics":{"gpt-5":{"usage":{"inputTokens":%d,"outputTokens":%d,"cacheReadTokens":%d,"cacheWriteTokens":0}}}}}`+"\n", in, out, cr)
	}
	os.WriteFile(p, []byte(`{"type":"session.start"}`+"\n"+shutdown(1000, 100, 600)), 0o600)
	if got := f.totals()["copilot|GitHub"]; got != 1100 {
		t.Fatalf("first %d", got)
	}
	// Resumed: the totals carry on, so only the growth counts.
	h, _ := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0)
	h.WriteString(shutdown(1500, 150, 900))
	h.Close()
	if got := f.totals()["copilot|GitHub"]; got != 1650 {
		t.Fatalf("resumed %d", got)
	}
}
