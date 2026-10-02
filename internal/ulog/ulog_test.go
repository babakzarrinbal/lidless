package ulog

import (
	"io"
	"os"
	"strings"
	"testing"
)

func TestFor(t *testing.T) {
	r, w, _ := os.Pipe()
	old := os.Stdout
	os.Stdout = w
	For("term")("x %d", 1)
	w.Close()
	os.Stdout = old
	b, _ := io.ReadAll(r)
	if !strings.HasSuffix(string(b), " term: x 1\n") {
		t.Fatalf("got %q", b)
	}
}
