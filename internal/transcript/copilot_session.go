package transcript

// Which session a running Copilot CLI has open. Copilot writes
// inuse.<pid>.lock into a session's folder only for a session it creates (1.0.9x
// writes none on --resume), so each process's own log is the record:
// ~/.copilot/logs/process-<ms>-<pid>.log says "Registering foreground session:
// <id>" whenever it opens one (new, --resume, /resume, /new) and
// "Unregistering …" when it lets go. The lock is the fallback for Copilots
// that don't log it.

import (
	"bufio"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
)

func copilotLogDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".copilot", "logs")
}

var reCopilotLog = regexp.MustCompile(`^process-(\d+)-(\d+)\.log$`)

// copilotLogs maps a pid to its newest process log (pids get reused).
func copilotLogs() map[int]string {
	files, _ := filepath.Glob(filepath.Join(copilotLogDir(), "process-*-*.log"))
	out, at := map[int]string{}, map[int]int64{}
	for _, f := range files {
		m := reCopilotLog.FindStringSubmatch(filepath.Base(f))
		if m == nil {
			continue
		}
		ms, _ := strconv.ParseInt(m[1], 10, 64)
		pid, _ := strconv.Atoi(m[2])
		if pid > 0 && ms >= at[pid] {
			out[pid], at[pid] = f, ms
		}
	}
	return out
}

var reForeground = regexp.MustCompile(`(Registering|Unregistering) foreground session: ([0-9a-fA-F-]{36})`)

// copilotLogScans remembers how far each log was read and the session it had
// open then: logs only grow, and the chat view asks every second or so.
var copilotLogScans = struct {
	sync.Mutex
	m map[string]logScan
}{m: map[string]logScan{}}

type logScan struct {
	off int64
	sid string
}

// copilotLogSession is the session the process that wrote log path has open
// now, "" for none.
func copilotLogSession(path string) string {
	copilotLogScans.Lock()
	s := copilotLogScans.m[path]
	copilotLogScans.Unlock()
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	if st, err := f.Stat(); err != nil || st.Size() < s.off {
		s = logScan{} // a new file under the old name
	}
	if _, err := f.Seek(s.off, io.SeekStart); err != nil {
		return s.sid
	}
	r := bufio.NewReaderSize(f, 64<<10)
	for {
		l, err := r.ReadString('\n')
		if err != nil { // a line still being written: read it next time
			break
		}
		s.off += int64(len(l))
		if m := reForeground.FindStringSubmatch(l); m != nil {
			switch {
			case m[1] == "Registering":
				s.sid = m[2]
			case m[2] == s.sid:
				s.sid = ""
			}
		}
	}
	copilotLogScans.Lock()
	copilotLogScans.m[path] = s
	copilotLogScans.Unlock()
	return s.sid
}

// copilotLocks maps a pid to the session whose inuse.<pid>.lock it holds.
func copilotLocks() map[int]string {
	m, _ := filepath.Glob(filepath.Join(copilotHome(), "*", "inuse.*.lock"))
	out := map[int]string{}
	for _, f := range m {
		pid, _ := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "inuse."), ".lock"))
		if pid > 0 {
			out[pid] = filepath.Base(filepath.Dir(f))
		}
	}
	return out
}

// copilotSessionOf is the session Copilot process pid has open: what its log
// says, else the lock it holds.
func copilotSessionOf(pid int, logs map[int]string, locks map[int]string) string {
	if f, ok := logs[pid]; ok {
		if sid := copilotLogSession(f); sid != "" {
			return sid
		}
	}
	return locks[pid]
}

type proc struct {
	ppid int
	comm string
}

// procs is every process's parent and command name, from one ps.
func procs() map[int]proc {
	out, _ := exec.Command("ps", "-A", "-o", "pid=,ppid=,comm=").Output()
	m := map[int]proc{}
	for _, l := range strings.Split(string(out), "\n") {
		f := strings.Fields(l)
		if len(f) < 3 {
			continue
		}
		c, _ := strconv.Atoi(f[0])
		p, _ := strconv.Atoi(f[1])
		m[c] = proc{p, strings.Join(f[2:], " ")}
	}
	return m
}

// copilotComm is whether a command name can be a Copilot CLI (its binary, or
// node running the npm package).
func copilotComm(comm string) bool {
	b := filepath.Base(comm)
	return b == "copilot" || b == "node"
}

// copilotTranscript finds the events file of a Copilot process running under pid.
func copilotTranscript(pid int) string {
	ps := procs()
	kids := map[int][]int{}
	for c, p := range ps {
		kids[p.ppid] = append(kids[p.ppid], c)
	}
	logs, locks := copilotLogs(), copilotLocks()
	for q := kids[pid]; len(q) > 0; q = q[1:] {
		sid := ""
		if copilotComm(ps[q[0]].comm) {
			sid = copilotSessionOf(q[0], logs, locks)
		}
		if sid == "" {
			q = append(q, kids[q[0]]...)
			continue
		}
		// No events.jsonl until the session's first message.
		p := filepath.Join(copilotHome(), sid, "events.jsonl")
		if _, err := os.Stat(p); err == nil {
			return p
		}
		return ""
	}
	return ""
}

// copilotRunning maps the id of each session a live Copilot holds to its pid.
func copilotRunning() map[string]int {
	out := map[string]int{}
	alive := func(pid int) bool {
		err := syscall.Kill(pid, 0)
		return err == nil || err == syscall.EPERM
	}
	for pid, sid := range copilotLocks() {
		if alive(pid) {
			out[sid] = pid
		}
	}
	var ps map[int]proc
	for pid, f := range copilotLogs() {
		if !alive(pid) {
			continue
		}
		if ps == nil {
			ps = procs()
		}
		if !copilotComm(ps[pid].comm) {
			continue // the pid went to another program
		}
		if sid := copilotLogSession(f); sid != "" {
			out[sid] = pid
		}
	}
	return out
}
