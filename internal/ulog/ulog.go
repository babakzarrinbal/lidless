// Package ulog is the one logger: a timestamped line on stdout, which the
// LaunchAgent or brew service writes to the agent log (`./dev.sh log`).
// Each package logs through its own prefix: ulog.For("term").
package ulog

import (
	"fmt"
	"time"
)

// Logf prints "2006-01-02 15:04:05 message".
func Logf(format string, a ...any) {
	fmt.Printf("%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, a...))
}

// For returns a logger whose lines start with "prefix: ".
func For(prefix string) func(format string, a ...any) {
	return func(format string, a ...any) {
		Logf("%s: %s", prefix, fmt.Sprintf(format, a...))
	}
}
