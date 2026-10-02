package main

// The agent's view of the terminals. Each one runs in its own holder process
// (internal/holder), which outlives the agent; the agent is one of its clients. It
// adopts every holder it finds, whoever started it (a phone, or
// `uniai claude` on the laptop), and mirrors its output for the phones.

import (
	"encoding/binary"
	"errors"
	"net"
	"os"
	"sort"
	"sync"
	"syscall"
	"time"

	"uniai/internal/holder"
	"uniai/internal/transcript"
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
	out     *holder.Ring

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
	end, _, _ := t.out.State()
	t.mu.Lock()
	defer t.mu.Unlock()
	return TermInfo{t.ID, t.title, t.cols, t.rows, end, t.Kind, t.Session, t.Dir, t.parked != "", t.seen}
}

// markSeen notes that a phone showed the output up to to; whether that is
// news for the others.
func (t *Term) markSeen(to int64) bool {
	end, _, _ := t.out.State()
	t.mu.Lock()
	defer t.mu.Unlock()
	if to <= t.seen || to > end {
		return false
	}
	t.seen = to
	return true
}

func (t *Term) read(from int64, max int) ([]byte, int64, bool, <-chan struct{}) {
	return t.out.Read(from, max)
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

// enterGap keeps a phone's Enter apart from the text before it. The phone
// sends them 120 ms apart, but the relay can deliver both at once, and a busy
// Claude then reads one chunk and takes the Enter as part of a paste: the
// message stays in its input box instead of being sent or queued.
const enterGap = 250 * time.Millisecond

// enterDelay is how long to hold input p back, sent [since] after the last.
func enterDelay(p []byte, since time.Duration) time.Duration {
	if string(p) != "\r" || since >= enterGap {
		return 0
	}
	return enterGap - since
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
// wins over it (see internal/holder).
func (t *Term) resize(cols, rows uint16) {
	if cols == 0 || rows == 0 {
		return
	}
	t.frame('r', holder.SizeFrame(cols, rows, 'p'))
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

// typedCommand is what to type into a new shell to start run: Copilot's
// command needs the shell's PATH (bash's login profile often lacks
// Homebrew's, zsh's has it), so it may change the shell too.
func typedCommand(shell, kind, run string) (string, string, error) {
	if kind != "copilot" {
		return shell, run, nil
	}
	typed, err := transcript.CopilotCommand(shell, run)
	if err == nil {
		return shell, typed, nil
	}
	if shell == "/bin/zsh" {
		return "", "", err
	}
	if typed, err = transcript.CopilotCommand("/bin/zsh", run); err != nil {
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
	id, err := holder.Spawn(holder.Spec{Shell: shell, Dir: dir, Kind: kind, Session: session, Run: run, Typed: typed, Cols: cols, Rows: rows}, logPath())
	if err != nil {
		return nil, err
	}
	t, err := m.adopt(id)
	if t == nil {
		return nil, errors.Join(errors.New("the terminal ended at once"), err)
	}
	return t, nil
}

// watch adopts holders as they appear (a laptop's `uniai claude`, or
// all of them after the agent restarts) and clears sockets left by holders
// that died.
func (m *Terms) watch() {
	for {
		m.scan()
		time.Sleep(time.Second)
	}
}

func (m *Terms) scan() {
	for _, id := range holder.IDs() {
		m.mu.Lock()
		skip := m.terms[id] != nil || m.adopting[id] || m.spawning > 0
		m.mu.Unlock()
		if skip {
			continue
		}
		if _, err := m.adopt(id); err != nil && errors.Is(err, syscall.ECONNREFUSED) {
			// Nobody listens: its holder was killed. A fresh one may not
			// listen yet, so only an old file goes.
			if st, err := os.Stat(holder.SockPath(id)); err == nil && time.Since(st.ModTime()) > 10*time.Second {
				os.Remove(holder.SockPath(id))
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
	c, info, err := holder.Dial(id)
	if err != nil {
		return nil, err
	}
	if info.Exited {
		c.Close()
		return nil, nil
	}
	t := &Term{ID: id, Created: time.UnixMilli(info.Created), Kind: info.Kind, Session: info.Session, Dir: info.Dir,
		pid: info.PID, run: info.Run, out: holder.NewRing(), title: info.Title, cols: info.Cols, rows: info.Rows,
		conn: c, send: make(chan []byte, 1024)}
	holder.WriteFrame(c, 'a', holder.I64(0)) // everything it kept
	m.mu.Lock()
	m.terms[id] = t
	m.mu.Unlock()
	done := make(chan struct{})
	go func() {
		var typed time.Time // the last input sent
		for {
			select {
			case f := <-t.send:
				if f[0] == 'i' {
					time.Sleep(enterDelay(f[5:], time.Since(typed)))
					typed = time.Now()
				}
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
			typ, p, err := holder.ReadFrame(c)
			if err != nil {
				break
			}
			switch typ {
			case 'o':
				if len(p) >= 8 {
					t.out.Write(int64(binary.BigEndian.Uint64(p)), p[8:])
				}
			case 's':
				if len(p) >= 4 {
					cols, rows := binary.BigEndian.Uint16(p), binary.BigEndian.Uint16(p[2:])
					t.mu.Lock()
					t.cols, t.rows = cols, rows
					t.mu.Unlock()
					// What the program draws next is a redraw for the new
					// size, not news: phones keep it out of their unread.
					end, _, _ := t.out.State()
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
		t.out.Exit(code)
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

// forChat is this terminal as the transcript readers see it.
func (t *Term) forChat() *transcript.Terminal {
	return &transcript.Terminal{ID: t.ID, Kind: t.Kind, Session: t.Session, Dir: t.Dir, Pid: t.pid, Run: t.run,
		Title: func() string { return t.info().Title }}
}

// forChat is every terminal as the transcript readers see them.
func (m *Terms) forChat() []*transcript.Terminal {
	ts := m.all()
	out := make([]*transcript.Terminal, len(ts))
	for i, t := range ts {
		out[i] = t.forChat()
	}
	return out
}

// mirrorVSCode runs for the agent's life (transcript.MirrorVSCode).
func (m *Terms) mirrorVSCode() { transcript.MirrorVSCode(m.forChat) }
