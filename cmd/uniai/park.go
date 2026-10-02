package main

// Parking: a session's Claude quits while the session sits idle off screen,
// so the conversation is free for the laptop or another phone, and starts
// again (--resume) in the same terminal when someone comes back to it.

import (
	"path/filepath"
	"strings"
	"time"

	"uniai/internal/transcript"
)

// claudeIn is the Claude running in terminal t: its conversation and pid.
func claudeIn(t *Term) (sid string, pid int) {
	shell := t.pid
	if shell <= 0 {
		return "", 0
	}
	var pp map[int]int
	for id, p := range transcript.ClaudeRunning() {
		if pp == nil {
			pp = transcript.Parents()
		}
		for q, n := pp[p], 0; q > 1 && n < 20; q, n = pp[q], n+1 {
			if q == shell {
				return id, p
			}
		}
	}
	return "", 0
}

// resumeCommand is the command the terminal started with (run), resuming
// conversation sid in place of any --continue or --resume it had.
func resumeCommand(run, sid string) string {
	f := strings.Fields(run)
	out := []string{"claude"}
	if len(f) > 0 && strings.Contains(filepath.Base(f[0]), "claude") {
		out[0], f = f[0], f[1:]
	} else {
		f = nil
	}
	for i := 0; i < len(f); i++ {
		switch f[i] {
		case "--continue", "-c":
			continue
		case "--resume", "-r", "--session-id":
			if i+1 < len(f) && !strings.HasPrefix(f[i+1], "-") {
				i++
			}
			continue
		}
		out = append(out, f[i])
	}
	return strings.Join(append(out, "--resume", sid), " ")
}

// park quits the Claude in t and remembers how to bring it back. It returns
// the conversation, or "" when no Claude runs there.
func (t *Term) park() (string, error) {
	sid, pid := claudeIn(t)
	if pid == 0 {
		return "", nil
	}
	if !transcript.QuitClaude(pid, 5*time.Second) {
		return "", &rpcError{Code: "busy", Msg: "Claude on the Mac did not quit"}
	}
	t.mu.Lock()
	t.parked, t.parkedID = resumeCommand(t.run, sid), sid
	t.mu.Unlock()
	return sid, nil
}

// unpark starts the parked Claude again, unless the conversation is open
// elsewhere now (the laptop picked it up): two Claudes on one conversation
// would each miss the other's messages. take quits that other Claude first.
func (t *Term) unpark(take bool) error {
	t.mu.Lock()
	cmd, sid := t.parked, t.parkedID
	t.mu.Unlock()
	if cmd == "" {
		return nil
	}
	if _, pid := claudeIn(t); pid == 0 {
		if _, open := transcript.ClaudeRunning()[sid]; open {
			if !take {
				return &rpcError{Code: "busy", Msg: "Claude has this conversation open somewhere else on the Mac"}
			}
			if err := transcript.StopClaude(sid); err != nil {
				return err
			}
		}
		t.write([]byte(cmd + "\r"))
	}
	t.mu.Lock()
	t.parked, t.parkedID = "", ""
	t.mu.Unlock()
	return nil
}
