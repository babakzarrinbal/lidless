package transcript

import (
	"os"
	"path/filepath"
	"testing"
)

// A resumed Copilot holds no inuse lock: its log names the session.
func TestCopilotSessionOf(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	logs := filepath.Join(home, ".copilot", "logs")
	os.MkdirAll(logs, 0o755)
	const fresh, resumed = "8850449f-1dc2-4b6d-ae42-0c23543d59e2", "18a5a9e7-5e98-49ef-ba83-5be1a9f3a39e"
	old := filepath.Join(logs, "process-1790000000000-4100.log") // the pid's earlier owner
	os.WriteFile(old, []byte("[INFO] Registering foreground session: 4ce35822-2ead-48ed-9c00-e3da87dc8638\n"), 0o644)
	f := filepath.Join(logs, "process-1790939113159-4100.log")
	os.WriteFile(f, []byte("[INFO] Registering foreground session: "+fresh+"\n"+
		"[INFO] Unregistering foreground session: "+fresh+"\n"+
		"[INFO] Registering foreground session: "+resumed+"\n[INFO] half a li"), 0o644)

	l := copilotLogs()
	if l[4100] != f {
		t.Fatalf("logs: got %v", l)
	}
	if got := copilotSessionOf(4100, l, map[int]string{4100: "lock"}); got != resumed {
		t.Fatalf("got %q, want the resumed session", got)
	}
	// Read on from where it stopped: quitting lets go of the session.
	a, _ := os.OpenFile(f, os.O_APPEND|os.O_WRONLY, 0)
	a.WriteString("ne\n[INFO] Unregistering foreground session: " + resumed + "\n")
	a.Close()
	if got := copilotLogSession(f); got != "" {
		t.Fatalf("after quitting: got %q", got)
	}
	// No log: the lock.
	if got := copilotSessionOf(4200, l, map[int]string{4200: fresh}); got != fresh {
		t.Fatalf("lock: got %q", got)
	}
}
