// Package holder is the process that owns one shared terminal, and the
// client side of the unix-socket protocol it speaks. A holder runs in a
// session of its own, so it outlives the agent: terminals survive an agent
// restart or upgrade. The frame format is in the header of holder.go and in
// docs/architecture.md ("Holder protocol"); it must stay backward compatible,
// because holders started by an older build are still adopted.
package holder

import (
	"fmt"
	"os"

	"uniai/internal/ulog"
)

var logf = ulog.For("hold")

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "uniai: "+format+"\n", a...)
	os.Exit(1)
}
