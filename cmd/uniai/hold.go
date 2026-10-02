package main

// A holder is one small process per terminal: it owns the pty and the login
// shell, keeps the recent output, and serves it on a unix socket. It runs in
// a session of its own (setsid), so it outlives the agent: restarting or
// upgrading the agent no longer ends anyone's terminal. Its clients are the
// agent (which serves it to every phone) and `uniai attach` on the Mac
// itself, any number at once: one terminal, seen and typed into everywhere.
//
// Socket: ~/.config/uniai/terms/<id>.sock (the folder is 0700).
// Frames: [type byte][len u32][payload]. Integers are big-endian.
//
//	holder → client
//	  'n' info JSON (holdInfo), always the first frame
//	  'o' [offset i64][bytes]  output, from the offset the client asked for
//	  's' [cols u16][rows u16] the pty's size changed
//	  'x' [code i32]           the shell exited; nothing more comes
//	client → holder
//	  'a' [from i64]           stream output from there (−1: from the end)
//	  'i' [bytes]              input
//	  'r' [cols][rows][role]   the client's size; role 'p' phones (via the agent),
//	                           'l' a laptop window, 'L' a laptop just attached (redraw)
//	  'h'                      hang up: SIGHUP the shell's group, SIGKILL after 3 s
//	  't' [title]              rename
//
// Size: while a laptop window is attached, the last laptop size wins (a
// screen is drawn for one size, and the laptop is where people sit);
// otherwise the phones' last size. Typing does not change the size.

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"

	"uniai/internal/config"
)

// holdProto is the socket protocol's version, in every 'n' frame. Holders
// outlive upgrades, so a new agent must still speak to an old holder.
const holdProto = 1

// ringKeep is how much output a terminal keeps for re-attaching clients.
const ringKeep = 1 << 20

func termsDir() string { return filepath.Join(config.Dir(), "terms") }

func sockPath(id uint32) string {
	return filepath.Join(termsDir(), strconv.FormatUint(uint64(id), 10)+".sock")
}

type holdInfo struct {
	V       int    `json:"v"`
	ID      uint32 `json:"id"`
	Kind    string `json:"kind"`
	Session string `json:"session"`
	Dir     string `json:"dir"`
	Title   string `json:"title"`
	Run     string `json:"run"`     // the command typed in first
	Created int64  `json:"created"` // unix ms
	PID     int    `json:"pid"`     // the shell
	Cols    uint16 `json:"cols"`
	Rows    uint16 `json:"rows"`
	End     int64  `json:"end"`
	Exited  bool   `json:"exited"`
	Code    int    `json:"code"`
}

// ring is a terminal's output: an append-only stream addressed by byte
// offset, of which the last ≤2*ringKeep bytes are kept. A client resumes
// exactly where it left off.
type ring struct {
	mu      sync.Mutex
	buf     []byte // ends at end
	end     int64  // total bytes ever written
	changed chan struct{}
	exited  bool
	code    int
}

func newRing() *ring { return &ring{changed: make(chan struct{})} }

func (r *ring) wake() {
	close(r.changed)
	r.changed = make(chan struct{})
}

// write puts p at offset off (−1: at the end). Bytes already kept are
// skipped; an offset past the end drops what is kept (the output between was
// lost), so the ring mirrors another one from any point.
func (r *ring) write(off int64, p []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if off < 0 {
		off = r.end
	}
	if off > r.end {
		r.buf, r.end = r.buf[:0], off
	}
	if skip := r.end - off; skip > 0 {
		if skip >= int64(len(p)) {
			return
		}
		p = p[skip:]
	}
	if len(p) == 0 {
		return
	}
	r.buf = append(r.buf, p...)
	r.end += int64(len(p))
	if len(r.buf) > 2*ringKeep {
		r.buf = append([]byte(nil), r.buf[len(r.buf)-ringKeep:]...)
	}
	r.wake()
}

// read returns up to max bytes from offset from. If from fell out of the
// buffer, reading restarts at the oldest kept byte (off > from says output
// was missed). With nothing to read it returns a channel that closes on the
// next write, and exited once the shell is gone.
func (r *ring) read(from int64, max int) (data []byte, off int64, exited bool, wait <-chan struct{}) {
	r.mu.Lock()
	defer r.mu.Unlock()
	start := r.end - int64(len(r.buf))
	if from < start || from > r.end {
		from = start
	}
	n := min(r.end-from, int64(max))
	if n > 0 {
		i := from - start
		data = append([]byte(nil), r.buf[i:i+n]...)
	}
	return data, from, r.exited && n == 0, r.changed
}

func (r *ring) exit(code int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.exited {
		return
	}
	r.exited, r.code = true, code
	r.wake()
}

func (r *ring) state() (end int64, exited bool, code int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.end, r.exited, r.code
}

// writeFrame sends one frame in a single write.
func writeFrame(w io.Writer, typ byte, parts ...[]byte) error {
	n := 0
	for _, p := range parts {
		n += len(p)
	}
	b := make([]byte, 5, 5+n)
	b[0] = typ
	binary.BigEndian.PutUint32(b[1:], uint32(n))
	for _, p := range parts {
		b = append(b, p...)
	}
	_, err := w.Write(b)
	return err
}

const frameMax = 1 << 20

func readFrame(r io.Reader) (byte, []byte, error) {
	var h [5]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(h[1:])
	if n > frameMax {
		return 0, nil, fmt.Errorf("frame of %d bytes", n)
	}
	p := make([]byte, n)
	if _, err := io.ReadFull(r, p); err != nil {
		return 0, nil, err
	}
	return h[0], p, nil
}

func i64(v int64) []byte { return binary.BigEndian.AppendUint64(nil, uint64(v)) }

func sizeFrame(cols, rows uint16, role byte) []byte {
	b := binary.BigEndian.AppendUint16(nil, cols)
	b = binary.BigEndian.AppendUint16(b, rows)
	if role != 0 {
		b = append(b, role)
	}
	return b
}

type holdClient struct {
	c      net.Conn
	mu     sync.Mutex // one frame at a time
	stop   chan struct{}
	laptop bool
	cols   uint16 // a laptop's last size
	rows   uint16
	seq    int // when it last sized
}

func (cl *holdClient) send(typ byte, parts ...[]byte) error {
	cl.mu.Lock()
	defer cl.mu.Unlock()
	cl.c.SetWriteDeadline(time.Now().Add(30 * time.Second))
	return writeFrame(cl.c, typ, parts...)
}

type holder struct {
	mu      sync.Mutex
	info    holdInfo
	out     *ring
	pty     *os.File
	inMu    sync.Mutex
	inQ     [][]byte // input waiting for the pty, in order
	inBusy  bool     // a goroutine is draining inQ
	clients map[*holdClient]struct{}
	phone   [2]uint16 // the phones' last size
	seq     int
}

// cmdHold runs a holder: `uniai hold -id N -dir D -shell S …`. The agent
// and `uniai claude` start it; nobody types this.
func cmdHold(args []string) {
	fs := flag.NewFlagSet("hold", flag.ExitOnError)
	id := fs.Uint64("id", 0, "terminal id")
	dir := fs.String("dir", "", "working folder")
	shell := fs.String("shell", "/bin/zsh", "login shell")
	kind := fs.String("kind", "shell", "claude, copilot or shell")
	session := fs.String("session", "", "session id")
	run := fs.String("run", "", "the command, as shown and resumed")
	typed := fs.String("type", "", "what to type into the shell first (default: run)")
	cols := fs.Uint("cols", 80, "")
	rows := fs.Uint("rows", 24, "")
	fs.Parse(args)
	if *id == 0 || *id > 1<<32-1 {
		die("hold needs -id")
	}
	if *typed == "" {
		*typed = *run
	}
	// Caught, not ignored: an ignored signal stays ignored across exec, so
	// the shell and everything it runs would ignore SIGHUP (hangup) and
	// SIGPIPE (`yes | head`).
	signal.Notify(make(chan os.Signal, 1), syscall.SIGHUP, syscall.SIGPIPE)
	if err := os.MkdirAll(termsDir(), 0o700); err != nil {
		die("%v", err)
	}
	path := sockPath(uint32(*id))
	os.Remove(path) // a stale one; the spawner picked an id nobody serves
	ln, err := net.Listen("unix", path)
	if err != nil {
		die("%v", err)
	}
	c, r := uint16(*cols), uint16(*rows)
	if c == 0 || r == 0 {
		c, r = 80, 24
	}
	cmd := exec.Command(*shell, "-l")
	cmd.Env = append(shellEnv(), "SHELL="+*shell, "UNIAI_TERM="+strconv.FormatUint(*id, 10))
	cmd.Dir = *dir
	f, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: c, Rows: r})
	if err != nil {
		ln.Close()
		os.Remove(path)
		die("%v", err)
	}
	title := filepath.Base(*shell)
	if *run != "" {
		title = strings.Fields(*run)[0]
	}
	h := &holder{
		info: holdInfo{V: holdProto, ID: uint32(*id), Kind: *kind, Session: *session, Dir: *dir, Title: title, Run: *run,
			Created: time.Now().UnixMilli(), PID: cmd.Process.Pid, Cols: c, Rows: r},
		out: newRing(), pty: f, clients: map[*holdClient]struct{}{}, phone: [2]uint16{c, r},
	}
	logf("hold %d: %s in %s (pid %d)", *id, title, *dir, cmd.Process.Pid)
	// A TERM (logout, kill) ends the shell the way a hangup does, so the
	// socket goes and the clients hear 'x'.
	term := make(chan os.Signal, 1)
	signal.Notify(term, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-term
		h.hangup()
	}()
	if *typed != "" {
		h.input([]byte(*typed + "\r")) // the shell reads it once it is up
	}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go h.serve(conn)
		}
	}()
	b := make([]byte, 32<<10)
	for {
		n, err := f.Read(b)
		if n > 0 {
			h.out.write(-1, b[:n])
		}
		if err != nil {
			break
		}
	}
	cmd.Wait()
	code := cmd.ProcessState.ExitCode()
	// No new clients; the ones attached read what is left, then 'x'.
	ln.Close()
	os.Remove(path)
	h.out.exit(code)
	logf("hold %d: exited (%d)", *id, code)
	for end := time.Now().Add(3 * time.Second); time.Now().Before(end); time.Sleep(50 * time.Millisecond) {
		h.mu.Lock()
		n := len(h.clients)
		h.mu.Unlock()
		if n == 0 {
			break
		}
	}
	f.Close()
}

func (h *holder) snapshot() holdInfo {
	h.mu.Lock()
	i := h.info
	h.mu.Unlock()
	i.End, i.Exited, i.Code = h.out.state()
	return i
}

// input queues p for the pty, in order. A program that does not read its
// input must not hold up a client's other frames, a hangup least of all.
func (h *holder) input(p []byte) {
	h.inMu.Lock()
	h.inQ = append(h.inQ, p)
	start := !h.inBusy
	h.inBusy = true
	h.inMu.Unlock()
	if start {
		go h.drainInput()
	}
}

func (h *holder) drainInput() {
	for {
		h.inMu.Lock()
		if len(h.inQ) == 0 {
			h.inBusy = false
			h.inMu.Unlock()
			return
		}
		p := h.inQ[0]
		h.inQ = h.inQ[1:]
		h.inMu.Unlock()
		h.pty.Write(p)
	}
}

func (h *holder) serve(c net.Conn) {
	cl := &holdClient{c: c}
	h.mu.Lock()
	h.clients[cl] = struct{}{}
	h.mu.Unlock()
	defer func() {
		c.Close()
		h.mu.Lock()
		delete(h.clients, cl)
		if cl.stop != nil {
			close(cl.stop)
		}
		h.mu.Unlock()
		if cl.laptop {
			h.resize() // the laptop left: the phones' size again
		}
	}()
	info, _ := json.Marshal(h.snapshot())
	if cl.send('n', info) != nil {
		return
	}
	for {
		typ, p, err := readFrame(c)
		if err != nil {
			return
		}
		switch typ {
		case 'a':
			if len(p) < 8 {
				return
			}
			from := int64(binary.BigEndian.Uint64(p))
			if from < 0 {
				from, _, _ = h.out.state()
			}
			stop := make(chan struct{})
			h.mu.Lock()
			if cl.stop != nil {
				close(cl.stop)
			}
			cl.stop = stop
			h.mu.Unlock()
			go h.stream(cl, from, stop)
		case 'i':
			h.input(p)
		case 'r':
			if len(p) < 5 {
				return
			}
			cols, rows := binary.BigEndian.Uint16(p), binary.BigEndian.Uint16(p[2:])
			if cols == 0 || rows == 0 {
				continue
			}
			h.mu.Lock()
			h.seq++
			if p[4] == 'p' {
				h.phone = [2]uint16{cols, rows}
			} else {
				cl.laptop, cl.cols, cl.rows, cl.seq = true, cols, rows, h.seq
			}
			h.mu.Unlock()
			if !h.resize() && p[4] == 'L' {
				go h.redraw()
			}
		case 'h':
			h.hangup()
		case 't':
			h.mu.Lock()
			h.info.Title = string(p)
			h.mu.Unlock()
		}
	}
}

// stream sends cl the output from offset from on, then 'x' once the shell
// has exited.
func (h *holder) stream(cl *holdClient, from int64, stop chan struct{}) {
	for {
		data, off, exited, wait := h.out.read(from, 32<<10)
		if len(data) > 0 {
			if cl.send('o', i64(off), data) != nil {
				cl.c.Close()
				return
			}
			from = off + int64(len(data))
			continue
		}
		if exited {
			_, _, code := h.out.state()
			cl.send('x', binary.BigEndian.AppendUint32(nil, uint32(int32(code))))
			return
		}
		select {
		case <-wait:
		case <-stop:
			return
		}
	}
}

// resize applies the size policy; whether the size changed.
func (h *holder) resize() bool {
	h.mu.Lock()
	size, best := h.phone, -1
	for cl := range h.clients {
		if cl.laptop && cl.seq > best {
			size, best = [2]uint16{cl.cols, cl.rows}, cl.seq
		}
	}
	if size[0] == h.info.Cols && size[1] == h.info.Rows {
		h.mu.Unlock()
		return false
	}
	h.info.Cols, h.info.Rows = size[0], size[1]
	clients := make([]*holdClient, 0, len(h.clients))
	for cl := range h.clients {
		clients = append(clients, cl)
	}
	h.mu.Unlock()
	pty.Setsize(h.pty, &pty.Winsize{Cols: size[0], Rows: size[1]})
	for _, cl := range clients {
		go cl.send('s', sizeFrame(size[0], size[1], 0))
	}
	return true
}

// redraw makes a full-screen program draw itself again for a window that
// just attached: one row less, then back, is a resize it must answer.
func (h *holder) redraw() {
	h.mu.Lock()
	cols, rows := h.info.Cols, h.info.Rows
	h.mu.Unlock()
	if rows < 2 {
		return
	}
	pty.Setsize(h.pty, &pty.Winsize{Cols: cols, Rows: rows - 1})
	time.Sleep(60 * time.Millisecond)
	h.mu.Lock()
	cols, rows = h.info.Cols, h.info.Rows // a resize meanwhile wins
	h.mu.Unlock()
	pty.Setsize(h.pty, &pty.Winsize{Cols: cols, Rows: rows})
}

// hangup ends the shell's process group, then kills it if it lingers.
func (h *holder) hangup() {
	pid := h.info.PID
	syscall.Kill(-pid, syscall.SIGHUP)
	time.AfterFunc(3*time.Second, func() {
		if _, exited, _ := h.out.state(); !exited {
			syscall.Kill(-pid, syscall.SIGKILL)
		}
	})
}

// holdSpec is what a new holder runs.
type holdSpec struct {
	Shell, Dir, Kind, Session, Run, Typed string
	Cols, Rows                            uint16
}

// spawnHold starts a holder in a session of its own and waits for its
// socket; the new terminal's id.
func spawnHold(s holdSpec) (uint32, error) {
	exe, err := os.Executable()
	if err != nil {
		return 0, err
	}
	if err := os.MkdirAll(termsDir(), 0o700); err != nil {
		return 0, err
	}
	id := freeTermID()
	cmd := exec.Command(exe, "hold", "-id", strconv.FormatUint(uint64(id), 10), "-dir", s.Dir, "-shell", s.Shell,
		"-kind", s.Kind, "-session", s.Session, "-run", s.Run, "-type", s.Typed,
		"-cols", strconv.Itoa(int(s.Cols)), "-rows", strconv.Itoa(int(s.Rows)))
	cmd.Dir = s.Dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} // out of the agent's (and launchd's) process group
	if lf, err := os.OpenFile(logPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
		cmd.Stdout, cmd.Stderr = lf, lf
		defer lf.Close()
	}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	done := make(chan struct{})
	go func() { cmd.Wait(); close(done) }() // reap it, should it end while we run
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(20 * time.Millisecond) {
		if c, err := net.Dial("unix", sockPath(id)); err == nil {
			c.Close()
			return id, nil
		}
		select {
		case <-done:
			return 0, errors.New("the terminal could not start; see " + logPath())
		default:
		}
	}
	return 0, errors.New("the terminal did not start in time")
}

// freeTermID is a random id no socket uses. Ids stay below 2^31 so they
// are plain ints everywhere.
func freeTermID() uint32 {
	for {
		id := rand.Uint32N(1<<31-1) + 1
		if _, err := os.Stat(sockPath(id)); os.IsNotExist(err) {
			return id
		}
	}
}

// dialHold connects to terminal id and reads its info.
func dialHold(id uint32) (net.Conn, holdInfo, error) {
	var info holdInfo
	c, err := net.DialTimeout("unix", sockPath(id), time.Second)
	if err != nil {
		return nil, info, err
	}
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	typ, p, err := readFrame(c)
	if err == nil && typ != 'n' {
		err = fmt.Errorf("terminal %d: unexpected frame %q", id, typ)
	}
	if err == nil {
		err = json.Unmarshal(p, &info)
	}
	if err == nil && (info.V < 1 || info.V > holdProto) { // older ones are still spoken
		err = fmt.Errorf("terminal %d speaks protocol %d; this uniai knows up to %d", id, info.V, holdProto)
	}
	if err != nil {
		c.Close()
		return nil, info, err
	}
	c.SetReadDeadline(time.Time{})
	return c, info, nil
}

// holdIDs lists the terminal ids that have a socket.
func holdIDs() []uint32 {
	files, _ := filepath.Glob(filepath.Join(termsDir(), "*.sock"))
	ids := make([]uint32, 0, len(files))
	for _, f := range files {
		n, err := strconv.ParseUint(strings.TrimSuffix(filepath.Base(f), ".sock"), 10, 32)
		if err == nil && n > 0 {
			ids = append(ids, uint32(n))
		}
	}
	return ids
}

// holdList is every live terminal's info (stale sockets are skipped).
func holdList() []holdInfo {
	var out []holdInfo
	for _, id := range holdIDs() {
		c, info, err := dialHold(id)
		if err != nil {
			continue
		}
		c.Close()
		out = append(out, info)
	}
	return out
}
