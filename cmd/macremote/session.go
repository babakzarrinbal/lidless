package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"strings"
	"sync"
	"time"

	"github.com/flynn/noise"
	"github.com/gorilla/websocket"
)

// Wire format, inside Noise transport messages:
//
//	ciphertext frame = [flag][chunk]          flag 1 = more chunks follow
//	app message      = [kind][body]
//	  'J' JSON         {"id","m","p"} request · {"id","r"|"e","code"} reply · {"ev","p"} event
//	  'O' term output  [id u32][offset u64][bytes]   mac → phone
//	  'I' term input   [id u32][bytes]               phone → mac
const (
	prologue  = "macremote/1"
	chunkMax  = 60000
	maxMsg    = 16 << 20
	readLimit = 256 << 10
)

var suite = noise.NewCipherSuite(noise.DH25519, noise.CipherChaChaPoly, noise.HashSHA256)

type Agent struct {
	mu       sync.Mutex
	cfg      *Config
	cfgMtime time.Time
	host     string
	terms    *Terms
	sessions map[*Session]struct{}
}

func logf(format string, a ...any) {
	fmt.Printf("%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, a...))
}

func computerName() string {
	if b, err := exec.Command("scutil", "--get", "ComputerName").Output(); err == nil {
		if s := strings.TrimSpace(string(b)); s != "" {
			return s
		}
	}
	h, _ := os.Hostname()
	return h
}

func (a *Agent) config() *Config {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.cfg
}

// reload rereads agent.json when it changed (pairing, `revoke`) and drops
// sessions of phones that are no longer listed.
func (a *Agent) reload() {
	st, err := os.Stat(configPath())
	if err != nil {
		return
	}
	a.mu.Lock()
	if st.ModTime().Equal(a.cfgMtime) {
		a.mu.Unlock()
		return
	}
	a.mu.Unlock()
	c, err := loadConfig()
	if err != nil {
		logf("config: %v", err)
		return
	}
	a.mu.Lock()
	a.cfg, a.cfgMtime = c, st.ModTime()
	var drop []*Session
	for s := range a.sessions {
		if c.device(s.pub) == nil {
			drop = append(drop, s)
		}
	}
	a.mu.Unlock()
	for _, s := range drop {
		logf("revoked: closing %s", s.device)
		s.close()
	}
}

func (a *Agent) dialer() *websocket.Dialer {
	pin := a.config().Pin
	return &websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
		ReadBufferSize:   32 << 10,
		WriteBufferSize:  32 << 10,
		TLSClientConfig: &tls.Config{
			MinVersion:         tls.VersionTLS13,
			InsecureSkipVerify: true, // replaced by the pin check below
			VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
				if len(raw) == 0 {
					return errors.New("no certificate")
				}
				sum := sha256.Sum256(raw[0])
				if hex.EncodeToString(sum[:]) != pin {
					return errors.New("relay certificate does not match the pin")
				}
				return nil
			},
		},
	}
}

// agentHeader carries the room key; only the agent's own connections send it.
func (a *Agent) agentHeader() http.Header {
	return http.Header{"Authorization": {"Bearer " + a.config().RoomKey}}
}

func (a *Agent) url(path string, extra url.Values) string {
	c := a.config()
	q := url.Values{"room": {c.Room}}
	for k, v := range extra {
		q[k] = v
	}
	return "wss://" + c.Relay + path + "?" + q.Encode()
}

// run keeps the control connection to the relay up forever.
func (a *Agent) run() {
	backoff := time.Second
	for {
		c, _, err := a.dialer().Dial(a.url("/v1/agent", nil), a.agentHeader())
		if err != nil {
			logf("relay: %v (retry in %s)", err, backoff)
			time.Sleep(backoff)
			backoff = min(backoff*2, 30*time.Second)
			continue
		}
		backoff = time.Second
		logf("relay: connected to %s", a.config().Relay)
		deadline := func() { c.SetReadDeadline(time.Now().Add(70 * time.Second)) }
		deadline()
		c.SetPingHandler(func(s string) error {
			deadline()
			return c.WriteControl(websocket.PongMessage, []byte(s), time.Now().Add(5*time.Second))
		})
		for {
			_, msg, err := c.ReadMessage()
			if err != nil {
				logf("relay: %v", err)
				break
			}
			deadline()
			var m struct{ T, Cid, IP string }
			if json.Unmarshal(msg, &m) == nil && m.T == "open" {
				go a.accept(m.Cid, m.IP)
			}
		}
		c.Close()
		time.Sleep(time.Second)
	}
}

func (a *Agent) accept(cid, ip string) {
	c, _, err := a.dialer().Dial(a.url("/v1/accept", url.Values{"cid": {cid}}), a.agentHeader())
	if err != nil {
		logf("accept: %v", err)
		return
	}
	c.SetReadLimit(readLimit)
	s := &Session{a: a, ws: c, ip: ip, out: make(chan []byte, 256), done: make(chan struct{}), pumps: map[uint32]chan struct{}{}}
	s.serve()
}

type hello struct {
	V    int    `json:"v"`
	Name string `json:"name"`
	Pair string `json:"pair,omitempty"`
}

// authorize decides whether the phone holding pub may in. A phone that is not
// listed gets in only with the one-time token from `macremote pair`.
func (a *Agent) authorize(pub string, h hello) (string, error) {
	a.reload()
	c := a.config()
	if d := c.device(pub); d != nil {
		return d.Name, nil
	}
	if h.Pair == "" {
		return "", errors.New("this phone is not paired with this Mac (or was removed)")
	}
	// Claim the token by renaming its file: the rename is atomic, so two phones
	// racing with the same code cannot both get in. A wrong code puts it back.
	claimed := pairingPath() + ".claimed"
	if err := os.Rename(pairingPath(), claimed); err != nil {
		return "", errors.New("pairing code expired or already used; run `macremote pair` again")
	}
	var p Pairing
	b, err := os.ReadFile(claimed)
	if err != nil || json.Unmarshal(b, &p) != nil || time.Now().After(p.Expires) {
		os.Remove(claimed)
		return "", errors.New("pairing code expired; run `macremote pair` again")
	}
	if subtle.ConstantTimeCompare([]byte(p.Token), []byte(h.Pair)) != 1 {
		os.Rename(claimed, pairingPath())
		return "", errors.New("wrong pairing code")
	}
	os.Remove(claimed) // single use
	name := strings.TrimSpace(h.Name)
	if name == "" || len(name) > 60 {
		name = "phone"
	}
	a.mu.Lock()
	nc := *a.cfg
	nc.Devices = append(append([]Device(nil), a.cfg.Devices...), Device{Name: name, Pub: pub, Added: time.Now()})
	a.mu.Unlock()
	if err := nc.save(); err != nil {
		return "", err
	}
	a.reload()
	logf("paired new phone %q (%s…)", name, pub[:12])
	return name, nil
}

type Session struct {
	a       *Agent
	ws      *websocket.Conn
	ip      string
	device  string
	pub     string
	send    *noise.CipherState
	recv    *noise.CipherState
	out     chan []byte
	done    chan struct{}
	once    sync.Once
	pumpsMu sync.Mutex
	pumps   map[uint32]chan struct{}
}

func (s *Session) close() {
	s.once.Do(func() {
		close(s.done)
		s.ws.Close()
	})
}

func (s *Session) serve() {
	defer s.close()
	cfg := s.a.config()
	key, err := cfg.key()
	if err != nil {
		logf("session: %v", err)
		return
	}
	s.ws.SetReadDeadline(time.Now().Add(15 * time.Second))
	_, m1, err := s.ws.ReadMessage()
	if err != nil {
		return
	}
	hs, err := noise.NewHandshakeState(noise.Config{CipherSuite: suite, Random: rand.Reader, Pattern: noise.HandshakeIK, Prologue: []byte(prologue), StaticKeypair: key})
	if err != nil {
		return
	}
	p1, _, _, err := hs.ReadMessage(nil, m1)
	if err != nil {
		logf("handshake from %s failed: %v", s.ip, err)
		return
	}
	var h hello
	json.Unmarshal(p1, &h)
	s.pub = hex.EncodeToString(hs.PeerStatic())
	name, authErr := s.a.authorize(s.pub, h)

	reply := map[string]any{"v": 1, "host": s.a.host}
	if authErr != nil {
		reply["err"] = authErr.Error()
	} else {
		u, _ := user.Current()
		home, _ := os.UserHomeDir()
		reply["user"], reply["home"], reply["roots"] = u.Username, home, cfg.Roots
	}
	rb, _ := json.Marshal(reply)
	m2, csIn, csOut, err := hs.WriteMessage(nil, rb)
	if err != nil {
		return
	}
	s.ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if s.ws.WriteMessage(websocket.BinaryMessage, m2) != nil {
		return
	}
	if authErr != nil {
		logf("refused %s… from %s: %v", s.pub[:12], s.ip, authErr)
		time.Sleep(time.Second) // let the reply reach the phone
		return
	}
	s.device, s.recv, s.send = name, csIn, csOut
	logf("connected: %s from %s", s.device, s.ip)
	s.a.mu.Lock()
	s.a.sessions[s] = struct{}{}
	s.a.mu.Unlock()
	defer func() {
		s.a.mu.Lock()
		delete(s.a.sessions, s)
		s.a.mu.Unlock()
		logf("disconnected: %s", s.device)
	}()

	go s.writer()
	s.ws.SetPingHandler(func(m string) error {
		s.ws.SetReadDeadline(time.Now().Add(70 * time.Second))
		return s.ws.WriteControl(websocket.PongMessage, []byte(m), time.Now().Add(5*time.Second))
	})
	var msg []byte
	for {
		s.ws.SetReadDeadline(time.Now().Add(70 * time.Second))
		_, ct, err := s.ws.ReadMessage()
		if err != nil {
			return
		}
		pt, err := s.recv.Decrypt(nil, nil, ct)
		if err != nil || len(pt) == 0 {
			logf("decrypt failed from %s: closing", s.device)
			return
		}
		msg = append(msg, pt[1:]...)
		if len(msg) > maxMsg {
			return
		}
		if pt[0] == 1 {
			continue
		}
		s.handle(msg)
		msg = nil
	}
}

// writer encrypts and sends queued app messages in order.
func (s *Session) writer() {
	defer s.close()
	for {
		select {
		case <-s.done:
			return
		case m := <-s.out:
			for len(m) > 0 {
				n := min(len(m), chunkMax)
				flag := byte(0)
				if n < len(m) {
					flag = 1
				}
				ct, err := s.send.Encrypt(nil, nil, append([]byte{flag}, m[:n]...))
				if err != nil {
					return
				}
				s.ws.SetWriteDeadline(time.Now().Add(30 * time.Second))
				if s.ws.WriteMessage(websocket.BinaryMessage, ct) != nil {
					return
				}
				m = m[n:]
			}
		}
	}
}

func (s *Session) queue(m []byte) bool {
	select {
	case s.out <- m:
		return true
	case <-s.done:
		return false
	}
}

func (s *Session) sendJSON(v any) {
	b, _ := json.Marshal(v)
	s.queue(append([]byte{'J'}, b...))
}

func (s *Session) handle(m []byte) {
	if len(m) == 0 {
		return
	}
	switch m[0] {
	case 'I':
		if len(m) < 5 {
			return
		}
		if t := s.a.terms.get(binary.BigEndian.Uint32(m[1:5])); t != nil {
			t.write(m[5:])
		}
	case 'J':
		var r struct {
			ID int64           `json:"id"`
			M  string          `json:"m"`
			P  json.RawMessage `json:"p"`
		}
		if json.Unmarshal(m[1:], &r) != nil {
			return
		}
		go func() {
			start := time.Now()
			res, err := s.call(r.M, r.P)
			if took := time.Since(start); err != nil || took > 3*time.Second {
				logf("%s %s: %v in %s", s.device, r.M, err, took.Round(time.Millisecond))
			}
			if err != nil {
				code := "error"
				var re *rpcError
				if errors.As(err, &re) {
					code = re.Code
				} else if os.IsNotExist(err) {
					code = "notfound"
				} else if os.IsPermission(err) {
					code = "denied"
				}
				s.sendJSON(map[string]any{"id": r.ID, "e": cleanErr(err), "code": code})
				return
			}
			s.sendJSON(map[string]any{"id": r.ID, "r": res})
		}()
	}
}

// cleanErr strips Go's "open /path: " prefixes the phone already knows.
func cleanErr(err error) string {
	var pe *os.PathError
	if errors.As(err, &pe) {
		return pe.Err.Error()
	}
	var le *os.LinkError
	if errors.As(err, &le) {
		return le.Err.Error()
	}
	return err.Error()
}

// pump streams one terminal's output from offset from until stopped.
func (s *Session) pump(t *Term, from int64, stop chan struct{}) {
	var hdr [12]byte
	binary.BigEndian.PutUint32(hdr[:4], t.ID)
	for {
		data, off, exited, wait := t.read(from, 48<<10)
		if len(data) > 0 {
			binary.BigEndian.PutUint64(hdr[4:], uint64(off))
			m := make([]byte, 0, 13+len(data))
			m = append(append(append(m, 'O'), hdr[:]...), data...)
			select {
			case s.out <- m:
			case <-stop:
				return
			case <-s.done:
				return
			}
			from = off + int64(len(data))
			continue
		}
		if exited {
			t.mu.Lock()
			code := t.code
			t.mu.Unlock()
			s.sendJSON(map[string]any{"ev": "term.exit", "p": map[string]any{"id": t.ID, "code": code}})
			return
		}
		select {
		case <-wait:
		case <-stop:
			return
		case <-s.done:
			return
		}
	}
}

func (s *Session) attach(t *Term, from int64) {
	stop := make(chan struct{})
	s.pumpsMu.Lock()
	if old := s.pumps[t.ID]; old != nil {
		close(old)
	}
	s.pumps[t.ID] = stop
	s.pumpsMu.Unlock()
	go s.pump(t, from, stop)
}

func (s *Session) detach(id uint32) {
	s.pumpsMu.Lock()
	if old := s.pumps[id]; old != nil {
		close(old)
		delete(s.pumps, id)
	}
	s.pumpsMu.Unlock()
}

func (s *Session) call(method string, raw json.RawMessage) (any, error) {
	var p struct {
		ID      uint32 `json:"id"`
		From    int64  `json:"from"`
		Before  int64  `json:"before"`
		Cols    uint16 `json:"cols"`
		Rows    uint16 `json:"rows"`
		Dir     string `json:"dir"`
		Title   string `json:"title"`
		Path    string `json:"path"`
		To      string `json:"to"`
		Text    string `json:"text"`
		Mtime   int64  `json:"mtime"`
		Kind    string `json:"kind"`
		Tool    string `json:"tool"`
		Account string `json:"account"`
		Session string `json:"session"`
		Cmd     string `json:"cmd"`
		Take    bool   `json:"take"` // term.unpark: quit the Claude that has the conversation elsewhere
		Shell   string `json:"shell"`
	}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
	}
	roots := s.a.config().Roots
	term := func() (*Term, error) {
		if t := s.a.terms.get(p.ID); t != nil {
			return t, nil
		}
		return nil, &rpcError{"gone", "that terminal has ended"}
	}
	switch method {
	case "term.list":
		return s.a.terms.list(), nil
	case "term.open":
		dir := p.Dir
		if dir == "" {
			dir, _ = os.UserHomeDir()
		} else {
			d, err := resolve(roots, dir)
			if err != nil {
				return nil, err
			}
			dir = d
		}
		if len(p.Session) > 64 || len(p.Kind) > 16 || len(p.Cmd) > 4096 || strings.ContainsAny(p.Cmd, "\r\n") {
			return nil, &rpcError{"bad", "bad terminal options"}
		}
		shell := pickShell(p.Shell, s.a.config().Shell, shells())
		t, err := s.a.terms.open(shell, dir, p.Cols, p.Rows, p.Kind, p.Session, strings.TrimSpace(p.Cmd))
		if err != nil {
			return nil, err
		}
		logf("%s opened terminal %d in %s", s.device, t.ID, dir)
		return t.info(), nil
	case "term.attach":
		t, err := term()
		if err != nil {
			return nil, err
		}
		t.resize(p.Cols, p.Rows)
		s.attach(t, p.From)
		return t.info(), nil
	case "term.detach":
		s.detach(p.ID)
		return true, nil
	case "term.resize":
		t, err := term()
		if err != nil {
			return nil, err
		}
		t.resize(p.Cols, p.Rows)
		return true, nil
	case "term.rename":
		t, err := term()
		if err != nil {
			return nil, err
		}
		t.mu.Lock()
		t.title = p.Title
		t.mu.Unlock()
		return true, nil
	case "term.close":
		t, err := term()
		if err != nil {
			return nil, err
		}
		logf("%s closed terminal %d", s.device, t.ID)
		sid, pid := claudeIn(t)
		go func() {
			// Claude first, so it saves the conversation for whoever picks it up.
			if pid != 0 {
				quitClaude(pid, 3*time.Second)
			}
			t.hangup()
		}()
		return map[string]any{"conversation": sid}, nil
	case "term.park":
		t, err := term()
		if err != nil {
			return nil, err
		}
		if t.Kind != "claude" {
			return map[string]any{"conversation": ""}, nil
		}
		sid, err := t.park()
		if sid != "" {
			logf("%s parked the idle Claude in terminal %d", s.device, t.ID)
		}
		return map[string]any{"conversation": sid}, err
	case "term.unpark":
		t, err := term()
		if err != nil {
			return nil, err
		}
		return true, t.unpark(p.Take)
	case "chat.read":
		t, err := term()
		if err != nil {
			return nil, err
		}
		return chatRead(t, p.From, p.Path)
	case "chat.older":
		t, err := term()
		if err != nil {
			return nil, err
		}
		return chatOlder(t, p.Before, p.Path)
	case "chat.sessions":
		dir, err := resolve(roots, p.Dir)
		if err != nil {
			return nil, err
		}
		return chatSessions(dir, s.a.terms.all())
	case "chat.recent":
		return chatRecent(s.a.terms.all(), 40, func(dir string) bool {
			_, err := resolve(roots, dir)
			return err == nil
		}), nil
	case "chat.commands":
		dir, _ := resolve(roots, p.Dir) // outside the shared folders: the user's commands only
		return chatCommands(dir, p.Kind), nil
	case "usage":
		return claudeUsage(), nil
	case "chat.stop":
		if err := stopClaude(p.Session); err != nil {
			return nil, err
		}
		logf("%s quit the Mac's Claude on conversation %s to take it over", s.device, p.Session)
		return true, nil
	case "tokens.reset":
		if !tokenLedger.reset(p.Tool, p.Account) {
			return nil, fmt.Errorf("no tokens counted for %s", p.Account)
		}
		logf("%s reset the token count of %s %s", s.device, p.Tool, p.Account)
		return tokenLedger.tokenTotals(), nil
	case "fs.list":
		return fsList(roots, p.Path)
	case "fs.read":
		return fsRead(roots, p.Path)
	case "fs.write":
		r, err := fsWrite(roots, p.Path, p.Text, p.Mtime)
		if err == nil {
			logf("%s saved %s", s.device, r["path"])
		}
		return r, err
	case "fs.mkdir":
		logf("%s mkdir %s", s.device, p.Path)
		return true, fsMkdir(roots, p.Path)
	case "fs.create":
		logf("%s create %s", s.device, p.Path)
		return true, fsCreate(roots, p.Path)
	case "fs.rename":
		logf("%s rename %s → %s", s.device, p.Path, p.To)
		return true, fsRename(roots, p.Path, p.To)
	case "fs.delete":
		logf("%s delete %s", s.device, p.Path)
		return true, fsDelete(roots, p.Path)
	case "sys.status":
		return sysStatus(s.a), nil
	case "shell.list":
		return shellInfo(s.a.config()), nil
	case "shell.set":
		if err := s.a.setShell(p.Shell); err != nil {
			return nil, err
		}
		logf("%s set the default shell to %q", s.device, p.Shell)
		return shellInfo(s.a.config()), nil
	}
	return nil, &rpcError{"unknown", "unknown method " + method}
}

func sysStatus(a *Agent) map[string]any {
	res := map[string]any{"host": a.host, "keepAwake": a.config().KeepAwake}
	if b, err := exec.Command("pmset", "-g").Output(); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			f := strings.Fields(l)
			if len(f) == 2 && f[0] == "SleepDisabled" {
				res["lidAwake"] = f[1] == "1"
			}
		}
	}
	if b, err := exec.Command("pmset", "-g", "batt").Output(); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if i := strings.Index(l, "\t"); i >= 0 && strings.Contains(l, "%") {
				res["battery"] = strings.TrimSpace(strings.SplitN(l[i+1:], " present", 2)[0])
			}
			if strings.Contains(l, "Now drawing from") {
				res["power"] = strings.Trim(strings.TrimPrefix(l, "Now drawing from "), "'")
			}
		}
	}
	return res
}
