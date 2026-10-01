package main

import (
	"reflect"
	"testing"
)

func TestParseShells(t *testing.T) {
	in := "# List of acceptable shells\n\n/bin/bash\n/bin/zsh\n/bin/zsh\n/opt/gone/fish\nnot/abs\n"
	got := parseShells(in, func(p string) bool { return p != "/opt/gone/fish" })
	if want := []string{"/bin/bash", "/bin/zsh"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestPickShell(t *testing.T) {
	offered := []string{"/bin/bash", "/bin/zsh"}
	cases := []struct{ want, def, out string }{
		{"/bin/bash", "/bin/zsh", "/bin/bash"},
		{"", "/bin/zsh", "/bin/zsh"},
		{"/tmp/evil", "/bin/bash", "/bin/bash"}, // only shells the Mac offers
	}
	for _, c := range cases {
		if got := pickShell(c.want, c.def, offered); got != c.out {
			t.Errorf("pickShell(%q, %q) = %q, want %q", c.want, c.def, got, c.out)
		}
	}
	if got := pickShell("/tmp/evil", "", offered); got == "/tmp/evil" {
		t.Errorf("pickShell ran a shell the Mac does not offer")
	}
}
