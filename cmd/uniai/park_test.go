package main

import "testing"

func TestResumeCommand(t *testing.T) {
	for run, want := range map[string]string{
		"claude --dangerously-skip-permissions --continue": "claude --dangerously-skip-permissions --resume abc-123",
		"claude --resume old-id --model opus":              "claude --model opus --resume abc-123",
		"/x/bin/claude -c":                                 "/x/bin/claude --resume abc-123",
		"":                                                 "claude --resume abc-123",
		"npm test":                                         "claude --resume abc-123",
	} {
		if got := resumeCommand(run, "abc-123"); got != want {
			t.Errorf("%q: %q", run, got)
		}
	}
}
