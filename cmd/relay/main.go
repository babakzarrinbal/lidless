// Command relay joins a Mac agent and a phone over WebSockets.
//
// It is a dumb pipe: everything it carries is end-to-end encrypted with Noise
// IK between the phone and the Mac, so the relay sees only room ids, byte
// counts and IP addresses. TLS uses a self-signed certificate that both ends
// pin by SHA-256, so no CA or domain is involved.
//
//	relay serve -addr :8460 -data /data   run the relay
//	relay pin -data /data                 print the certificate pin
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/time/rate"
)

const (
	maxFrame         = 256 << 10
	maxPhonesPerRoom = 8
	acceptTimeout    = 10 * time.Second
	pingEvery        = 20 * time.Second
	readTimeout      = 60 * time.Second
)

var roomRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

var upgrader = websocket.Upgrader{ReadBufferSize: 32 << 10, WriteBufferSize: 32 << 10}

type room struct {
	agent   *websocket.Conn
	agentMu *sync.Mutex // serialises text writes on agent
	pending map[string]chan *websocket.Conn
	phones  int
}

type hub struct {
	mu    sync.Mutex
	rooms map[string]*room

	// Agent connections must present the room's key. The first key seen for
	// a room claims it (sha256 kept in claimsPath), so knowing a room id from
	// a pairing code is enough to reach the Mac but not to stand in for it.
	claimsMu   sync.Mutex
	claims     map[string]string // room -> hex sha256(key)
	claimsPath string

	limMu sync.Mutex
	lims  map[string]*rate.Limiter
}

func (h *hub) room(id string) *room {
	r := h.rooms[id]
	if r == nil {
		r = &room{pending: map[string]chan *websocket.Conn{}}
		h.rooms[id] = r
	}
	return r
}

// gc drops a room with nothing in it. Call with h.mu held.
func (h *hub) gc(id string) {
	if r := h.rooms[id]; r != nil && r.agent == nil && r.phones == 0 && len(r.pending) == 0 {
		delete(h.rooms, id)
	}
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// allow rate-limits connection attempts per IP (30/min, burst 15).
func (h *hub) allow(ip string) bool {
	h.limMu.Lock()
	defer h.limMu.Unlock()
	l := h.lims[ip]
	if l == nil {
		if len(h.lims) > 10000 {
			h.lims = map[string]*rate.Limiter{}
		}
		l = rate.NewLimiter(rate.Every(2*time.Second), 15)
		h.lims[ip] = l
	}
	return l.Allow()
}

func short(id string) string { return id[:6] }

func loadClaims(path string) map[string]string {
	m := map[string]string{}
	if b, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(b, &m); err != nil {
			log.Fatalf("claims: %v", err)
		}
	}
	return m
}

var keyRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// owns reports whether the request carries the room's agent key, claiming
// the room for that key if nobody has yet.
func (h *hub) owns(id string, r *http.Request) bool {
	key, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || !keyRe.MatchString(key) {
		return false
	}
	s := sha256.Sum256([]byte(key))
	sum := hex.EncodeToString(s[:])
	h.claimsMu.Lock()
	defer h.claimsMu.Unlock()
	if have, ok := h.claims[id]; ok {
		return subtle.ConstantTimeCompare([]byte(have), []byte(sum)) == 1
	}
	if len(h.claims) >= 100000 {
		return false
	}
	h.claims[id] = sum
	b, _ := json.MarshalIndent(h.claims, "", " ")
	tmp := h.claimsPath + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil || os.Rename(tmp, h.claimsPath) != nil {
		log.Printf("claims: cannot save: %v", err)
		delete(h.claims, id)
		return false
	}
	log.Printf("room claimed room=%s ip=%s", short(id), clientIP(r))
	return true
}

// agentGate is gate plus the room key check for the agent's endpoints.
func (h *hub) agentGate(w http.ResponseWriter, r *http.Request) (string, bool) {
	id, ok := h.gate(w, r)
	if !ok {
		return "", false
	}
	if !h.owns(id, r) {
		log.Printf("agent refused room=%s ip=%s", short(id), clientIP(r))
		http.Error(w, "not this room's agent", http.StatusForbidden)
		return "", false
	}
	return id, true
}

// keepalive pings c until it fails and keeps its read deadline fresh.
func keepalive(c *websocket.Conn, done <-chan struct{}) {
	c.SetReadDeadline(time.Now().Add(readTimeout))
	c.SetPongHandler(func(string) error { return c.SetReadDeadline(time.Now().Add(readTimeout)) })
	t := time.NewTicker(pingEvery)
	defer t.Stop()
	for {
		select {
		case <-done:
			return
		case <-t.C:
			if c.WriteControl(websocket.PingMessage, nil, time.Now().Add(10*time.Second)) != nil {
				c.Close()
				return
			}
		}
	}
}

func closeWith(c *websocket.Conn, code int, msg string) {
	c.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(code, msg), time.Now().Add(2*time.Second))
	c.Close()
}

func (h *hub) gate(w http.ResponseWriter, r *http.Request) (string, bool) {
	if !h.allow(clientIP(r)) {
		http.Error(w, "slow down", http.StatusTooManyRequests)
		return "", false
	}
	id := r.URL.Query().Get("room")
	if !roomRe.MatchString(id) {
		http.Error(w, "bad room", http.StatusBadRequest)
		return "", false
	}
	return id, true
}

// agent is the Mac's long-lived control connection for a room.
func (h *hub) agent(w http.ResponseWriter, r *http.Request) {
	id, ok := h.agentGate(w, r)
	if !ok {
		return
	}
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c.SetReadLimit(4 << 10)
	h.mu.Lock()
	rm := h.room(id)
	old := rm.agent
	rm.agent, rm.agentMu = c, &sync.Mutex{}
	h.mu.Unlock()
	if old != nil {
		closeWith(old, 4001, "replaced")
	}
	log.Printf("agent up   room=%s ip=%s", short(id), clientIP(r))

	done := make(chan struct{})
	go keepalive(c, done)
	for {
		if _, _, err := c.ReadMessage(); err != nil {
			break
		}
		c.SetReadDeadline(time.Now().Add(readTimeout))
	}
	close(done)
	c.Close()
	h.mu.Lock()
	if rm.agent == c {
		rm.agent = nil
	}
	h.gc(id)
	h.mu.Unlock()
	log.Printf("agent down room=%s", short(id))
}

// phone asks the room's agent to dial back, then pipes the two sockets.
func (h *hub) phone(w http.ResponseWriter, r *http.Request) {
	id, ok := h.gate(w, r)
	if !ok {
		return
	}
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c.SetReadLimit(maxFrame)
	h.mu.Lock()
	rm := h.rooms[id]
	if rm == nil || rm.agent == nil {
		h.mu.Unlock()
		closeWith(c, 4404, "mac offline")
		return
	}
	if rm.phones >= maxPhonesPerRoom {
		h.mu.Unlock()
		closeWith(c, 4429, "too many connections")
		return
	}
	cid := randHex(16)
	ch := make(chan *websocket.Conn, 1)
	rm.pending[cid] = ch
	rm.phones++
	agent, mu := rm.agent, rm.agentMu
	h.mu.Unlock()

	defer func() {
		h.mu.Lock()
		delete(rm.pending, cid)
		rm.phones--
		h.gc(id)
		h.mu.Unlock()
	}()

	open, _ := json.Marshal(map[string]string{"t": "open", "cid": cid, "ip": clientIP(r)})
	mu.Lock()
	agent.SetWriteDeadline(time.Now().Add(5 * time.Second))
	err = agent.WriteMessage(websocket.TextMessage, open)
	mu.Unlock()
	if err != nil {
		closeWith(c, 4404, "mac offline")
		return
	}
	select {
	case a := <-ch:
		log.Printf("pipe open  room=%s ip=%s", short(id), clientIP(r))
		up, down := pipe(c, a)
		log.Printf("pipe close room=%s up=%d down=%d", short(id), up, down)
	case <-time.After(acceptTimeout):
		closeWith(c, 4408, "mac did not answer")
	}
}

// accept is the agent dialing back for one phone connection.
func (h *hub) accept(w http.ResponseWriter, r *http.Request) {
	id, ok := h.agentGate(w, r)
	if !ok {
		return
	}
	cid := r.URL.Query().Get("cid")
	h.mu.Lock()
	var ch chan *websocket.Conn
	if rm := h.rooms[id]; rm != nil {
		ch = rm.pending[cid]
		delete(rm.pending, cid)
	}
	h.mu.Unlock()
	if ch == nil {
		http.Error(w, "unknown connection", http.StatusNotFound)
		return
	}
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c.SetReadLimit(maxFrame)
	ch <- c
}

// pipe copies frames both ways until either side ends. It returns bytes
// carried phone→mac and mac→phone.
func pipe(phone, mac *websocket.Conn) (up, down int64) {
	done := make(chan struct{})
	go keepalive(phone, done)
	go keepalive(mac, done)
	var wg sync.WaitGroup
	cp := func(dst, src *websocket.Conn, n *int64) {
		defer wg.Done()
		for {
			t, b, err := src.ReadMessage()
			if err != nil {
				break
			}
			src.SetReadDeadline(time.Now().Add(readTimeout))
			dst.SetWriteDeadline(time.Now().Add(30 * time.Second))
			if dst.WriteMessage(t, b) != nil {
				break
			}
			*n += int64(len(b))
		}
		phone.Close()
		mac.Close()
	}
	wg.Add(2)
	go cp(mac, phone, &up)
	go cp(phone, mac, &down)
	wg.Wait()
	close(done)
	return
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// loadCert reads data/cert.pem + key.pem, creating a 20-year self-signed
// P-256 certificate on first start.
func loadCert(dir string) (tls.Certificate, error) {
	cf, kf := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	if _, err := os.Stat(cf); os.IsNotExist(err) {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return tls.Certificate{}, err
		}
		serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
		tmpl := &x509.Certificate{
			SerialNumber: serial,
			Subject:      pkix.Name{CommonName: "macremote-relay"},
			NotBefore:    time.Now().Add(-time.Hour),
			NotAfter:     time.Now().AddDate(20, 0, 0),
			KeyUsage:     x509.KeyUsageDigitalSignature,
			ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		}
		der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
		if err != nil {
			return tls.Certificate{}, err
		}
		kb, _ := x509.MarshalECPrivateKey(key)
		if err := os.WriteFile(kf, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600); err != nil {
			return tls.Certificate{}, err
		}
		if err := os.WriteFile(cf, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
			return tls.Certificate{}, err
		}
	}
	return tls.LoadX509KeyPair(cf, kf)
}

func pin(c tls.Certificate) string {
	s := sha256.Sum256(c.Certificate[0])
	return hex.EncodeToString(s[:])
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: relay serve|pin [-addr :8460] [-data dir]")
		os.Exit(2)
	}
	fs := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	addr := fs.String("addr", ":8460", "listen address")
	data := fs.String("data", "/data", "directory for the TLS certificate")
	fs.Parse(os.Args[2:])

	cert, err := loadCert(*data)
	if err != nil {
		log.Fatal(err)
	}
	if os.Args[1] == "pin" {
		fmt.Println(pin(cert))
		return
	}

	cp := filepath.Join(*data, "claims.json")
	h := &hub{rooms: map[string]*room{}, lims: map[string]*rate.Limiter{}, claims: loadClaims(cp), claimsPath: cp}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/agent", h.agent)
	mux.HandleFunc("/v1/phone", h.phone)
	mux.HandleFunc("/v1/accept", h.accept)
	srv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13},
		ErrorLog:          log.New(os.Stderr, "http: ", 0),
	}
	log.Printf("relay on %s pin=%s", *addr, pin(cert))
	log.Fatal(srv.ListenAndServeTLS("", ""))
}
