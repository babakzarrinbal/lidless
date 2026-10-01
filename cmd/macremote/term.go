package main

// The agent's view of the terminals. Each one runs in its own holder process
// (hold.go), which outlives the agent; the agent is one of its clients. It
// adopts every holder it finds, whoever started it (a phone, or
// `macremote claude` on the laptop), and mirrors its output for the phones.

import (
	"encoding/binary"
	"errors"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Term is the agent's end of one holder. Its output is an append-only stream
// addressed by byte offset, so a phone resumes exactly where it left off.
type Term struct {
	ID      uint32
	Created time.Time
	Kind    string // the agent ("claude", "copilot") or "shell"; the phone groups terminals by Session
	Session string
	Dir     string
	pid     int // the shell
	run     string
	out     *ring

	mu       sync.Mutex
	title    string
	cols     uint16
	rows     uint16
	parked   string // the command that brings a parked Claude back
	parkedID string // its conversation
	seen     int64  // read up to here on some phone; shared by all of them

	conn net.Conn
	send chan []byte // frames to the holder, in order
}

type TermInfo struct {
	ID      uint32 `json:"id"`
	Title   string `json:"title"`
	Cols    uint16 `json:"cols"`
	Rows    uint16 `json:"rows"`
	End     int64  `json:"end"`
	Kind    string `json:"kind,omitempty"`
	Session string `json:"session,omitempty"`
	Dir     string `json:"dir"`
	Parked  bool   `json:"parked,omitempty"` // its Claude quit while idle; term.unpark brings it back
	Seen    int64  `json:"seen,omitempty"`   // read up to here on some phone
}

func (t *Term) info() TermInfo {
	end, _, _ := t.out.state()
	t.mu.Lock()
	defer t.mu.Unlock()
	return TermInfo{t.ID, t.title, t.cols, t.rows, end, t.Kind, t.Session, t.Dir, t.parked != "", t.seen}
}

// markSeen notes that a phone showed the output up to to; whether that is
// news for the others.
func (t *Term) markSeen(to int64) bool {
	end, _, _ := t.out.state()
	t.mu.Lock()
	defer t.mu.Unlock()
	if to <= t.seen || to > end {
		return false
	}
	t.seen = to
	return true
}

func (t *Term) read(from int64, max int) ([]byte, int64, bool, <-chan struct{}) {
	return t.out.read(from, max)
}

func (t *Term) frame(typ byte, p []byte) {
	b := make([]byte, 5, 5+len(p))
	b[0] = typ
	binary.BigEndian.PutUint32(b[1:], uint32(len(p)))
	select {
	case t.send <- append(b, p...):
	default:
		logf("term %d: queue full, dropped a %q frame of %d bytes", t.ID, typ, len(p))
	}
}

// write queues input for the shell. A program that is not reading its input
// must not stall the phone's whole connection, so the holder gets it on the
// terminal's own goroutine.
func (t *Term) write(p []byte) {
	for len(p) > 0 { // frames stay small
		n := min(len(p), 32<<10)
		t.frame('i', p[:n])
		p = p[n:]
	}
}

// resize is the phones' size; a laptop window attached to the same terminal
// wins over it (see hold.go).
func (t *Term) resize(cols, rows uint16) {
	if cols == 0 || rows == 0 {
		return
	}
	t.frame('r', sizeFrame(cols, rows, 'p'))
}

func (t *Term) rename(title string) {
	t.mu.Lock()
	t.title = title
	t.mu.Unlock()
	t.frame('t', []byte(title))
}

// hangup ends the shell's process group (the holder kills it if it lingers).
func (t *Term) hangup() { t.frame('h', nil) }

type Terms struct {
	mu       sync.Mutex
	terms    map[uint32]*Term
	adopting map[uint32]bool
	spawning int
	onChange func()                            // a terminal came or went
	onEvent  func(ev string, p map[string]any) // for every phone: term.size, term.seen
}

func newTerms() *Terms {
	return &Terms{terms: map[uint32]*Term{}, adopting: map[uint32]bool{}}
}

func (m *Terms) get(id uint32) *Term {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.terms[id]
}

func (m *Terms) all() []*Term {
	m.mu.Lock()
	defer m.mu.Unlock()
	ts := make([]*Term, 0, len(m.terms))
	for _, t := range m.terms {
		ts = append(ts, t)
	}
	return ts
}

func (m *Terms) list() []TermInfo {
	ts := m.all()
	sort.Slice(ts, func(i, j int) bool { return ts[i].Created.Before(ts[j].Created) })
	out := make([]TermInfo, len(ts))
	for i, t := range ts {
		out[i] = t.info()
	}
	return out
}

func (m *Terms) changed() {
	if m.onChange != nil {
		m.onChange()
	}
}

func (m *Terms) event(ev string, p map[string]any) {
	if m.onEvent != nil {
		m.onEvent(ev, p)
	}
}

func shellEnv() []string {
	env := []string{}
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "XPC_SERVICE_NAME", "XPC_FLAGS", "MACREMOTE_TERM":
			continue
		}
		env = append(env, kv)
	}
	env = append(env, "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=MacRemote")
	if os.Getenv("LANG") == "" {
		env = append(env, "LANG=en_US.UTF-8")
	}
	return env
}

// typedCommand is what to type into a new shell to start run: Copilot's
// command needs the shell's PATH (bash's login profile often lacks
// Homebrew's, zsh's has it), so it may change the shell too.
func typedCommand(shell, kind, run string) (string, string, error) {
	if kind != "copilot" {
		return shell, run, nil
	}
	typed, err := copilotCommand(shell, run)
	if err == nil {
		return shell, typed, nil
	}
	if shell == "/bin/zsh" {
		return "", "", err
	}
	if typed, err = copilotCommand("/bin/zsh", run); err != nil {
		return "", "", err
	}
	return "/bin/zsh", typed, nil
}

// open starts a login shell in dir in a new holder. A non-empty run is typed
// into it as the first command, so quitting that program leaves the shell.
func (m *Terms) open(shell, dir string, cols, rows uint16, kind, session, run string) (*Term, error) {
	if cols == 0 || rows == 0 {
		cols, rows = 80, 24
	}
	shell, typed, err := typedCommand(shell, kind, run)
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	m.spawning++ // scan waits, so this call adopts its own terminal
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		m.spawning--
		m.mu.Unlock()
	}()
	id, err := spawnHold(holdSpec{Shell: shell, Dir: dir, Kind: kind, Session: session, Run: run, Typed: typed, Cols: cols, Rows: rows})
	if err != nil {
		return nil, err
	}
	t, err := m.adopt(id)
	if t == nil {
		return nil, errors.Join(errors.New("the terminal ended at once"), err)
	}
	return t, nil
}

// watch adopts holders as they appear (a laptop's `macremote claude`, or
// all of them after the agent restarts) and clears sockets left by holders
// that died.
func (m *Terms) watch() {
	for {
		m.scan()
		time.Sleep(time.Second)
	}
}

func (m *Terms) scan() {
	for _, id := range holdIDs() {
		m.mu.Lock()
		skip := m.terms[id] != nil || m.adopting[id] || m.spawning > 0
		m.mu.Unlock()
		if skip {
			continue
		}
		if _, err := m.adopt(id); err != nil && errors.Is(err, syscall.ECONNREFUSED) {
			// Nobody listens: its holder was killed. A fresh one may not
			// listen yet, so only an old file goes.
			if st, err := os.Stat(sockPath(id)); err == nil && time.Since(st.ModTime()) > 10*time.Second {
				os.Remove(sockPath(id))
				logf("term %d: removed a dead terminal's socket", id)
			}
		}
	}
}

// adopt connects to holder id and starts mirroring it. It returns nil
// without error when the terminal is already adopted or has just ended.
func (m *Terms) adopt(id uint32) (*Term, error) {
	m.mu.Lock()
	if m.terms[id] != nil || m.adopting[id] {
		m.mu.Unlock()
		return nil, nil
	}
	m.adopting[id] = true
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		delete(m.adopting, id)
		m.mu.Unlock()
	}()
	c, info, err := dialHold(id)
	if err != nil {
		return nil, err
	}
	if info.Exited {
		c.Close()
		return nil, nil
	}
	t := &Term{ID: id, Created: time.UnixMilli(info.Created), Kind: info.Kind, Session: info.Session, Dir: info.Dir,
		pid: info.PID, run: info.Run, out: newRing(), title: info.Title, cols: info.Cols, rows: info.Rows,
		conn: c, send: make(chan []byte, 1024)}
	writeFrame(c, 'a', i64(0)) // everything it kept
	m.mu.Lock()
	m.terms[id] = t
	m.mu.Unlock()
	done := make(chan struct{})
	go func() {
		for {
			select {
			case f := <-t.send:
				c.SetWriteDeadline(time.Now().Add(30 * time.Second))
				if _, err := c.Write(f); err != nil {
					c.Close()
					return
				}
			case <-done:
				return
			}
		}
	}()
	go func() {
		defer close(done)
		code := -1 // gone without saying: the holder died
		for {
			typ, p, err := readFrame(c)
			if err != nil {
				break
			}
			switch typ {
			case 'o':
				if len(p) >= 8 {
					t.out.write(int64(binary.BigEndian.Uint64(p)), p[8:])
				}
			case 's':
				if len(p) >= 4 {
					cols, rows := binary.BigEndian.Uint16(p), binary.BigEndian.Uint16(p[2:])
					t.mu.Lock()
					t.cols, t.rows = cols, rows
					t.mu.Unlock()
					// What the program draws next is a redraw for the new
					// size, not news: phones keep it out of their unread.
					end, _, _ := t.out.state()
					m.event("term.size", map[string]any{"id": id, "cols": cols, "rows": rows, "at": end})
				}
			case 'x':
				if len(p) >= 4 {
					code = int(int32(binary.BigEndian.Uint32(p)))
				}
			}
			if typ == 'x' {
				break
			}
		}
		c.Close()
		t.out.exit(code)
		m.mu.Lock()
		delete(m.terms, id)
		m.mu.Unlock()
		logf("term %d exited (%d)", id, code)
		m.changed()
	}()
	logf("term %d: %s %s in %s", id, info.Kind, info.Title, info.Dir)
	m.changed()
	return t, nil
}
