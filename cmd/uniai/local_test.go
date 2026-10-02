package main

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestLocal(t *testing.T) {
	home, err := os.MkdirTemp("", "h") // short: a unix socket path has ~104 bytes
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(home)
	t.Setenv("HOME", home)
	c, err := ensureConfig()
	if err != nil || c.Relay != "" || c.KeepAwake || c.Pub == "" {
		t.Fatalf("config for this Mac alone: %+v %v", c, err)
	}
	a := &Agent{cfg: c, host: "test-mac", terms: newTerms(), plugins: corePlugins(), sessions: map[*Session]struct{}{}}
	go a.serveLocal()
	for i := 0; i < 100; i++ {
		if _, err := os.Stat(localSock()); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if st, err := os.Stat(localSock()); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("socket: %v %v", st, err)
	}
	d := websocket.Dialer{NetDialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", localSock())
	}}
	ws, _, err := d.Dial("ws://localhost/v1/local", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	ws.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, m, err := ws.ReadMessage()
	var hi map[string]any
	if err != nil || json.Unmarshal(m, &hi) != nil || hi["host"] != "test-mac" || hi["home"] != home {
		t.Fatalf("welcome: %s %v", m, err)
	}
	// One app message in one frame: [flag 0]['J'][json].
	ws.WriteMessage(websocket.BinaryMessage, append([]byte{0, 'J'}, `{"id":7,"m":"plugins.list"}`...))
	_, m, err = ws.ReadMessage()
	if err != nil || len(m) < 2 || m[0] != 0 || m[1] != 'J' {
		t.Fatalf("reply: %q %v", m, err)
	}
	var r struct {
		ID int
		R  []struct{ Name string }
	}
	if json.Unmarshal(m[2:], &r) != nil || r.ID != 7 || len(r.R) == 0 || r.R[0].Name != "git" {
		t.Fatalf("plugins.list: %s", m[2:])
	}
	// The local app is not a paired phone: a config reload keeps it.
	os.Chtimes(configPath(), time.Now(), time.Now().Add(time.Second))
	a.reload()
	a.mu.Lock()
	n := len(a.sessions)
	a.mu.Unlock()
	if n != 1 {
		t.Fatalf("sessions after reload: %d", n)
	}
}
