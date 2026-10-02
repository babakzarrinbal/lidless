package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// Homebrew renamed its service labels from homebrew.mxcl.* to sh.brew.*.
var brewLabels = []string{"sh.brew.uniai", "homebrew.mxcl.uniai"}

// holdAgentLock makes sure only one agent serves this config. Two copies (a
// brew service and a `uniai install` LaunchAgent) would share a room and
// knock each other off the relay every few seconds, dropping every phone.
// A second copy waits here, quietly, and takes over if the first one stops.
// The lock lives as long as the process (the file stays open).
func holdAgentLock() {
	os.MkdirAll(configDir(), 0o700)
	path := filepath.Join(configDir(), "agent.lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		logf("lock: %v (running without one)", err)
		return
	}
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		b, _ := os.ReadFile(path)
		logf("another uniai agent is already running (pid %s); waiting for it to stop. "+
			"Run only one: `brew services` or `uniai install`, not both.", strings.TrimSpace(string(b)))
		if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
			die("lock: %v", err)
		}
	}
	f.Truncate(0)
	f.WriteAt([]byte(strconv.Itoa(os.Getpid())+"\n"), 0)
	lockFile = f // keep it open (and locked) for the process's life
}

var lockFile *os.File

// brewServiceLoaded reports whether `brew services` runs the agent.
func brewServiceLoaded() bool { return brewServiceLabel() != "" }

func brewServiceLabel() string {
	for _, l := range brewLabels {
		if launchctl("print", domain()+"/"+l) == nil {
			return l
		}
	}
	return ""
}

func brewServiceHint() string {
	return fmt.Sprintf("uniai already runs as a brew service (%s); restart it with `brew services restart uniai`", brewServiceLabel())
}
