package main

// With "pmset disablesleep 1" the Mac stays awake with its lid shut, but
// macOS can leave the built-in screen lit behind the lid (it turns back on
// when the agent restarts, say): heat and battery for nothing. While the lid
// is shut, keep the display asleep, unless an external monitor is what the
// Mac is showing on (then closing the lid is just clamshell mode).

import (
	"os/exec"
	"strings"
	"time"
)

// lidShut reads the lid from ioreg: shut, and whether that would normally
// sleep the Mac (false when an external monitor is attached).
func lidShut() (shut, alone bool) {
	b, err := exec.Command("ioreg", "-r", "-k", "AppleClamshellState", "-d", "1").Output()
	if err != nil {
		return false, false
	}
	return lidParse(string(b))
}

func lidParse(s string) (shut, alone bool) {
	for _, l := range strings.Split(s, "\n") {
		k, v, ok := strings.Cut(l, "=")
		if !ok {
			continue
		}
		yes := strings.TrimSpace(v) == "Yes"
		switch strings.Trim(strings.TrimSpace(k), `"`) {
		case "AppleClamshellState":
			shut = yes
		case "AppleClamshellCausesSleep":
			alone = yes
		}
	}
	return shut, alone
}

// keepDisplayOffWhenShut turns the display off when the lid shuts, and again
// every minute while it stays shut, in case something woke it.
func keepDisplayOffWhenShut() {
	var last time.Time
	for range time.Tick(3 * time.Second) {
		shut, alone := lidShut()
		if !shut || !alone {
			last = time.Time{}
			continue
		}
		if time.Since(last) < time.Minute {
			continue
		}
		if err := exec.Command("pmset", "displaysleepnow").Run(); err != nil {
			logf("display off: %v", err)
		} else if last.IsZero() {
			logf("lid shut: display off")
		}
		last = time.Now()
	}
}
