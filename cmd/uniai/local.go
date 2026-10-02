package main

import (
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/gorilla/websocket"

	"uniai/internal/config"
)

// The app on this Mac talks to its own core over a unix socket in the config
// folder: the same app messages as a phone session (wire.go, rpc.go), as a
// WebSocket, but without the relay and without Noise. The folder and the
// socket are the owner's only, so whoever connects is this user.
//
// The core speaks first, with the welcome a phone gets after its handshake.
func localSock() string { return filepath.Join(config.Dir(), "core.sock") }

func (a *Agent) serveLocal() {
	path := localSock()
	os.MkdirAll(filepath.Dir(path), 0o700)
	os.Remove(path) // this agent holds the lock: a socket left here is stale
	l, err := net.Listen("unix", path)
	if err != nil {
		logf("local: %v (this Mac's app cannot connect)", err)
		return
	}
	os.Chmod(path, 0o600)
	up := websocket.Upgrader{ReadBufferSize: 32 << 10, WriteBufferSize: 32 << 10}
	srv := &http.Server{ReadHeaderTimeout: 10 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/local" {
			http.NotFound(w, r)
			return
		}
		c, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		c.SetReadLimit(readLimit)
		s := &Session{a: a, ws: c, ip: "local", out: make(chan []byte, 256), done: make(chan struct{}), pumps: map[uint32]chan struct{}{}}
		s.serveLocal()
	})}
	logf("local: serving this Mac's app on %s", path)
	logf("local: %v", srv.Serve(l))
}

func (s *Session) serveLocal() {
	defer s.close()
	b, _ := json.Marshal(s.a.welcome())
	s.ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if s.ws.WriteMessage(websocket.BinaryMessage, b) != nil {
		return
	}
	s.device, s.local, s.send, s.recv = "this Mac's app", true, plain{}, plain{}
	logf("connected: %s", s.device)
	s.run()
}
