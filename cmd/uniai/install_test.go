package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBundledRelay(t *testing.T) {
	app := t.TempDir()
	exe := filepath.Join(app, "MacOS", "uniai")
	os.MkdirAll(filepath.Join(app, "MacOS"), 0o755)
	if r, _ := bundledRelay(exe); r != "" {
		t.Fatalf("no Resources/relay gave %q", r)
	}
	os.MkdirAll(filepath.Join(app, "Resources"), 0o755)
	pin := strings.Repeat("ab", 32)
	os.WriteFile(filepath.Join(app, "Resources", "relay"), []byte("relay.example:8460 "+pin+"\n"), 0o644)
	if r, p := bundledRelay(exe); r != "relay.example:8460" || p != pin {
		t.Fatalf("got %q %q", r, p)
	}
	os.WriteFile(filepath.Join(app, "Resources", "relay"), []byte("relay.example:8460 short"), 0o644)
	if r, _ := bundledRelay(exe); r != "" {
		t.Fatalf("a bad pin was taken: %q", r)
	}
}

func TestReplaces(t *testing.T) {
	for _, c := range []struct {
		mine, theirs string
		want         bool
	}{
		{"20261002.120000", "20261001.090000", true},
		{"20261001.090000", "20261002.120000", false}, // an old app never downgrades
		{"20261002.120000", "20261002.120000", false},
		{"20261002.120000", "", true}, // a core from before stamps, or none running
		{"dev", "20261002.120000", false},
		{"dev", "", true},
	} {
		if got := replaces(c.mine, c.theirs); got != c.want {
			t.Errorf("replaces(%q, %q) = %v", c.mine, c.theirs, got)
		}
	}
}

func TestLinkCLI(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	link := filepath.Join(home, ".local", "bin", "uniai")
	linkCLI("/x/uniai")
	if cur, _ := os.Readlink(link); cur != "/x/uniai" {
		t.Fatalf("link points at %q", cur)
	}
	linkCLI("/y/uniai") // an old link is moved
	if cur, _ := os.Readlink(link); cur != "/y/uniai" {
		t.Fatalf("link points at %q", cur)
	}
	os.Remove(link)
	os.WriteFile(link, []byte("mine"), 0o755)
	linkCLI("/y/uniai") // a real file is left alone
	if b, _ := os.ReadFile(link); string(b) != "mine" {
		t.Fatal("a file that is not our link was replaced")
	}
}
