package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

func TestRingMirror(t *testing.T) {
	r := newRing()
	r.write(-1, []byte("hello "))
	r.write(-1, []byte("world"))
	if d, off, _, _ := r.read(0, 100); string(d) != "hello world" || off != 0 {
		t.Fatalf("read %q at %d", d, off)
	}
	// A mirror starting mid-stream, then overlapping and repeated frames.
	m := newRing()
	m.write(6, []byte("world"))
	m.write(8, []byte("rld!"))
	m.write(6, []byte("wor"))
	if d, off, _, _ := m.read(0, 100); string(d) != "world!" || off != 6 {
		t.Fatalf("mirror %q at %d", d, off)
	}
	// A gap drops what was kept.
	m.write(100, []byte("x"))
	if d, off, _, _ := m.read(0, 100); string(d) != "x" || off != 100 {
		t.Fatalf("after gap %q at %d", d, off)
	}
	m.exit(3)
	if _, _, exited, _ := m.read(101, 10); !exited {
		t.Fatal("not exited")
	}
	if _, ex, code := m.state(); !ex || code != 3 {
		t.Fatalf("state %v %d", ex, code)
	}
}

func TestRingTrim(t *testing.T) {
	r := newRing()
	chunk := bytes.Repeat([]byte{'a'}, 64<<10)
	for range 2*ringKeep/len(chunk) + 1 {
		r.write(-1, chunk)
	}
	end, _, _ := r.state()
	d, off, _, _ := r.read(0, 1<<30)
	if off+int64(len(d)) != end || len(d) > 2*ringKeep || len(d) < ringKeep {
		t.Fatalf("kept %d bytes from %d of %d", len(d), off, end)
	}
}

func TestFrames(t *testing.T) {
	var b bytes.Buffer
	writeFrame(&b, 'o', i64(42), []byte("data"))
	writeFrame(&b, 'h')
	typ, p, err := readFrame(&b)
	if err != nil || typ != 'o' || binary.BigEndian.Uint64(p) != 42 || string(p[8:]) != "data" {
		t.Fatalf("%c %q %v", typ, p, err)
	}
	if typ, p, err = readFrame(&b); err != nil || typ != 'h' || len(p) != 0 {
		t.Fatalf("%c %q %v", typ, p, err)
	}
}

// TestHolderClients runs a holder's socket side against a pipe instead of a
// pty: two clients see the same output, input from either arrives, and the
// size follows a laptop while one is attached.
func TestHolderClients(t *testing.T) {
	pr, pw, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer pr.Close()
	h := &holder{info: holdInfo{V: holdProto, ID: 7, Kind: "claude", Cols: 80, Rows: 24}, out: newRing(), pty: pw,
		clients: map[*holdClient]struct{}{}, phone: [2]uint16{80, 24}}
	dial := func() net.Conn {
		a, b := net.Pipe()
		go h.serve(b)
		typ, p, err := readFrame(a)
		if err != nil || typ != 'n' || !strings.Contains(string(p), `"id":7`) {
			t.Fatalf("info: %c %s %v", typ, p, err)
		}
		return a
	}
	agent, laptop := dial(), dial()
	go writeFrame(agent, 'a', i64(0))
	h.out.write(-1, []byte("hi"))
	expect := func(c net.Conn, want byte) []byte {
		t.Helper()
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		for {
			typ, p, err := readFrame(c)
			if err != nil {
				t.Fatalf("waiting for %c: %v", want, err)
			}
			if typ == want {
				return p
			}
		}
	}
	if p := expect(agent, 'o'); string(p[8:]) != "hi" {
		t.Fatalf("agent got %q", p)
	}
	go writeFrame(laptop, 'a', i64(-1)) // from the end: nothing old
	time.Sleep(50 * time.Millisecond)
	h.out.write(-1, []byte("yo"))
	if p := expect(laptop, 'o'); binary.BigEndian.Uint64(p) != 2 || string(p[8:]) != "yo" {
		t.Fatalf("laptop got %q", p)
	}
	go writeFrame(laptop, 'i', []byte("ls\r"))
	buf := make([]byte, 16)
	if n, _ := pr.Read(buf); string(buf[:n]) != "ls\r" {
		t.Fatalf("pty got %q", buf[:n])
	}

	// pty.Setsize fails on a pipe; the policy is what is tested.
	go writeFrame(agent, 'r', sizeFrame(40, 30, 'p'))
	expect(agent, 's')
	if h.snapshot().Cols != 40 {
		t.Fatalf("phone size not applied: %+v", h.snapshot())
	}
	go writeFrame(laptop, 'r', sizeFrame(120, 40, 'L'))
	expect(agent, 's')
	go writeFrame(agent, 'r', sizeFrame(50, 30, 'p'))
	time.Sleep(100 * time.Millisecond)
	if i := h.snapshot(); i.Cols != 120 || i.Rows != 40 {
		t.Fatalf("laptop should win: %dx%d", i.Cols, i.Rows)
	}
	laptop.Close()
	if p := expect(agent, 's'); binary.BigEndian.Uint16(p) != 50 {
		t.Fatalf("after the laptop left: %v", p)
	}

	h.out.exit(5)
	if p := expect(agent, 'x'); binary.BigEndian.Uint32(p) != 5 {
		t.Fatalf("exit %v", p)
	}
}

// TestInputQueues: input for a program that does not read it must not block
// the client's frame loop, or a hangup behind it would never be read.
func TestInputQueues(t *testing.T) {
	pr, pw, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer pr.Close()
	h := &holder{pty: pw}
	done := make(chan struct{})
	go func() {
		h.input(bytes.Repeat([]byte{'x'}, 1<<20)) // far more than a pipe holds
		h.input([]byte("end"))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("input blocked")
	}
	got, err := io.ReadAll(io.LimitReader(pr, 1<<20+3))
	if err != nil || len(got) != 1<<20+3 || string(got[1<<20:]) != "end" {
		t.Fatalf("read %d bytes, %v", len(got), err)
	}
}
