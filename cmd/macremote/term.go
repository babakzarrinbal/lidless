package main

import (
	"math/rand/v2"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// ringKeep is how much output a terminal keeps for re-attaching phones.
const ringKeep = 1 << 20

// Term is a shell on a pty that outlives phone connections. Its output is an
// append-only stream addressed by byte offset, so a phone can resume exactly
// where it left off after a reconnect.
type Term struct {
	ID      uint32
	Created time.Time
	Kind    string // "claude" or "shell"; the phone groups terminals by Session
	Session string
	Dir     string

	mu      sync.Mutex
	title   string
	buf     []byte // the last ≤2*ringKeep bytes of output, ending at end
	end     int64  // total bytes ever written
	changed chan struct{}
	exited  bool
	code    int
	cols    uint16
	rows    uint16

	in  chan []byte
	pty *os.File
	cmd *exec.Cmd
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
}

func (t *Term) info() TermInfo {
	t.mu.Lock()
	defer t.mu.Unlock()
	return TermInfo{t.ID, t.title, t.cols, t.rows, t.end, t.Kind, t.Session, t.Dir}
}

func (t *Term) append(p []byte) {
	t.mu.Lock()
	t.buf = append(t.buf, p...)
	t.end += int64(len(p))
	if len(t.buf) > 2*ringKeep {
		t.buf = append([]byte(nil), t.buf[len(t.buf)-ringKeep:]...)
	}
	close(t.changed)
	t.changed = make(chan struct{})
	t.mu.Unlock()
}

// read returns up to max bytes from offset from. If from fell out of the
// buffer, reading restarts at the oldest kept byte (off > from tells the
// phone it missed output). With nothing to read it returns a channel that
// closes on the next write, and exited once the shell is gone.
func (t *Term) read(from int64, max int) (data []byte, off int64, exited bool, wait <-chan struct{}) {
	t.mu.Lock()
	defer t.mu.Unlock()
	start := t.end - int64(len(t.buf))
	if from < start || from > t.end {
		from = start
	}
	n := t.end - from
	if n > int64(max) {
		n = int64(max)
	}
	if n > 0 {
		i := from - start
		data = append([]byte(nil), t.buf[i:i+n]...)
	}
	return data, from, t.exited && n == 0, t.changed
}

// write queues input for the shell. A program that is not reading its input
// must not stall the phone's whole connection, so the pty write happens on
// the terminal's own goroutine.
func (t *Term) write(p []byte) {
	select {
	case t.in <- append([]byte(nil), p...):
	default:
		logf("term %d: input queue full, dropped %d bytes", t.ID, len(p))
	}
}

func (t *Term) resize(cols, rows uint16) {
	if cols == 0 || rows == 0 {
		return
	}
	t.mu.Lock()
	t.cols, t.rows = cols, rows
	t.mu.Unlock()
	pty.Setsize(t.pty, &pty.Winsize{Cols: cols, Rows: rows})
}

// hangup ends the shell's process group, then kills it if it lingers.
func (t *Term) hangup() {
	pid := t.cmd.Process.Pid
	syscall.Kill(-pid, syscall.SIGHUP)
	time.AfterFunc(3*time.Second, func() {
		t.mu.Lock()
		gone := t.exited
		t.mu.Unlock()
		if !gone {
			syscall.Kill(-pid, syscall.SIGKILL)
		}
	})
}

type Terms struct {
	mu    sync.Mutex
	next  uint32
	terms map[uint32]*Term
}

func newTerms() *Terms {
	// Random start so ids from a previous agent run are never reused.
	return &Terms{next: rand.Uint32N(1 << 30), terms: map[uint32]*Term{}}
}

func (m *Terms) get(id uint32) *Term {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.terms[id]
}

func (m *Terms) list() []TermInfo {
	m.mu.Lock()
	ts := make([]*Term, 0, len(m.terms))
	for _, t := range m.terms {
		ts = append(ts, t)
	}
	m.mu.Unlock()
	sort.Slice(ts, func(i, j int) bool { return ts[i].Created.Before(ts[j].Created) })
	out := make([]TermInfo, len(ts))
	for i, t := range ts {
		out[i] = t.info()
	}
	return out
}

func shellEnv() []string {
	env := []string{}
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "XPC_SERVICE_NAME", "XPC_FLAGS":
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

// open starts a login shell in dir on a fresh pty. A non-empty run is typed
// into it as the first command, so quitting that program leaves the shell.
func (m *Terms) open(dir string, cols, rows uint16, kind, session, run string) (*Term, error) {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}
	if cols == 0 || rows == 0 {
		cols, rows = 80, 24
	}
	cmd := exec.Command(shell, "-l")
	cmd.Env = shellEnv()
	cmd.Dir = dir
	f, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: cols, Rows: rows})
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	m.next++
	id := m.next
	t := &Term{ID: id, Created: time.Now(), Kind: kind, Session: session, Dir: dir, changed: make(chan struct{}), cols: cols, rows: rows, pty: f, cmd: cmd, in: make(chan []byte, 1024)}
	t.title = shell[strings.LastIndex(shell, "/")+1:]
	if run != "" {
		t.title = strings.Fields(run)[0]
		t.in <- []byte(run + "\r")
	}
	m.terms[id] = t
	m.mu.Unlock()

	stopIn := make(chan struct{})
	go func() {
		for {
			select {
			case p := <-t.in:
				if _, err := f.Write(p); err != nil {
					return
				}
			case <-stopIn:
				return
			}
		}
	}()
	go func() {
		defer close(stopIn)
		b := make([]byte, 32<<10)
		for {
			n, err := f.Read(b)
			if n > 0 {
				t.append(b[:n])
			}
			if err != nil {
				break
			}
		}
		cmd.Wait()
		f.Close()
		t.mu.Lock()
		t.exited = true
		t.code = cmd.ProcessState.ExitCode()
		close(t.changed)
		t.changed = make(chan struct{})
		t.mu.Unlock()
		m.mu.Lock()
		delete(m.terms, id)
		m.mu.Unlock()
		logf("term %d exited (%d)", id, t.code)
	}()
	return t, nil
}
