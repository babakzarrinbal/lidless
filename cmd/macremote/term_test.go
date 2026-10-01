package main

import "testing"

// A phone's "seen" offset only moves forward and never past the output.
func TestMarkSeen(t *testing.T) {
	tm := &Term{out: newRing()}
	tm.out.write(0, make([]byte, 100))
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
