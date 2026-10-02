package main

import (
	"testing"
	"time"

	"uniai/internal/holder"
)

// A phone's "seen" offset only moves forward and never past the output.
func TestMarkSeen(t *testing.T) {
	tm := &Term{out: holder.NewRing()}
	tm.out.Write(0, make([]byte, 100))
	for _, c := range []struct {
		to   int64
		want bool
	}{{50, true}, {50, false}, {20, false}, {101, false}, {100, true}} {
		if got := tm.markSeen(c.to); got != c.want {
			t.Errorf("markSeen(%d) = %v, want %v", c.to, got, c.want)
		}
	}
	if tm.seen != 100 {
		t.Errorf("seen = %d, want 100", tm.seen)
	}
}

// A lone Enter right after text waits out the gap; anything else goes now.
func TestEnterDelay(t *testing.T) {
	for _, c := range []struct {
		p     string
		since time.Duration
		want  time.Duration
	}{
		{"\r", 50 * time.Millisecond, enterGap - 50*time.Millisecond},
		{"\r", time.Second, 0},
		{"hello", 0, 0},
		{"ls\r", 0, 0},
	} {
		if got := enterDelay([]byte(c.p), c.since); got != c.want {
			t.Errorf("enterDelay(%q, %v) = %v, want %v", c.p, c.since, got, c.want)
		}
	}
}
