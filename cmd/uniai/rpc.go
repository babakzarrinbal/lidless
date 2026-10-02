package main

// The app-facing RPC: one message from a device in, one answer out. The
// method switch is in call; the wire and the handshake are in wire.go.

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"uniai/internal/fsops"
	"uniai/internal/plugin"
	"uniai/internal/transcript"
	"uniai/internal/usage"
)

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
			_, _, code := t.out.State()
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
		Seen    int64  `json:"seen"`
		Size    int64  `json:"size"`
		VSCode  bool   `json:"vscode"` // chat.sessions/recent: VS Code's chats too (an app that can show them)
		Pub     string `json:"pub"`    // devices.*: the phone's key
		Name    string `json:"name"`   // devices.rename
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
		return nil, &rpcError{Code: "gone", Msg: "that terminal has ended"}
	}
	switch method {
	case "term.list":
		return s.a.terms.list(), nil
	case "term.open":
		dir := p.Dir
		if dir == "" {
			dir, _ = os.UserHomeDir()
		} else {
			d, err := fsops.Resolve(roots, dir)
			if err != nil {
				return nil, err
			}
			dir = d
		}
		if len(p.Session) > 64 || len(p.Kind) > 16 || len(p.Cmd) > 4096 || strings.ContainsAny(p.Cmd, "\r\n") {
			return nil, &rpcError{Code: "bad", Msg: "bad terminal options"}
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
	case "term.seen": // a phone showed this output: read on every phone
		t, err := term()
		if err != nil {
			return nil, err
		}
		if t.markSeen(p.Seen) {
			s.a.termEvent("term.seen", map[string]any{"id": t.ID, "seen": p.Seen})
		}
		return true, nil
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
		t.rename(p.Title)
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
				transcript.QuitClaude(pid, 3*time.Second)
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
		return transcript.ChatRead(t.forChat(), p.From, p.Path)
	case "chat.older":
		t, err := term()
		if err != nil {
			return nil, err
		}
		return transcript.ChatOlder(t.forChat(), p.Before, p.Path)
	case "chat.sessions":
		dir, err := fsops.Resolve(roots, p.Dir)
		if err != nil {
			return nil, err
		}
		l, err := transcript.ChatSessions(dir, s.a.terms.forChat())
		if err == nil && p.VSCode {
			l = transcript.MergeConversations(l, transcript.VSCodeConversations(transcript.ListMax, func(c *transcript.Conversation) bool { return c.Dir == dir }), transcript.ListMax)
		}
		return l, err
	case "chat.recent":
		shared := func(dir string) bool {
			_, err := fsops.Resolve(roots, dir)
			return err == nil
		}
		l := transcript.ChatRecent(s.a.terms.forChat(), 40, shared)
		if p.VSCode {
			l = transcript.MergeConversations(l, transcript.VSCodeConversations(40, func(c *transcript.Conversation) bool { return shared(c.Dir) }), 40)
		}
		return l, nil
	case "chat.transcript": // a VS Code chat, read-only: {"same": true} while size and mtime still match
		return transcript.VSCodeTranscript(p.Session, p.Size, p.Mtime, func(dir string) bool {
			_, err := fsops.Resolve(roots, dir)
			return err == nil
		})
	case "chat.handoff": // a VS Code chat written out for an agent in a shared terminal: {"path", "prompt"}
		go func() { // so VS Code opens that terminal too (internal/transcript/vscodemirror.go)
			if msg, err := transcript.VSCodeExtInstall(false); err != nil {
				logf("vscode extension: %v", err)
			} else if strings.HasPrefix(msg, "installed") {
				logf("vscode extension: %s", msg)
			}
		}()
		return transcript.VSCodeHandoff(p.Session, func(dir string) bool {
			_, err := fsops.Resolve(roots, dir)
			return err == nil
		})
	case "chat.commands":
		dir, _ := fsops.Resolve(roots, p.Dir) // outside the shared folders: the user's commands only
		return transcript.ChatCommands(dir, p.Kind), nil
	case "usage":
		return usage.ClaudeUsage(), nil
	case "chat.stop":
		if err := transcript.StopClaude(p.Session); err != nil {
			return nil, err
		}
		logf("%s quit the Mac's Claude on conversation %s to take it over", s.device, p.Session)
		return true, nil
	case "tokens.reset":
		if !usage.TokenLedger.Reset(p.Tool, p.Account) {
			return nil, fmt.Errorf("no tokens counted for %s", p.Account)
		}
		logf("%s reset the token count of %s %s", s.device, p.Tool, p.Account)
		return usage.TokenLedger.TokenTotals(), nil
	case "fs.list":
		return fsops.List(roots, p.Path)
	case "fs.read":
		return fsops.Read(roots, p.Path)
	case "fs.write":
		r, err := fsops.Write(roots, p.Path, p.Text, p.Mtime)
		if err == nil {
			logf("%s saved %s", s.device, r["path"])
		}
		return r, err
	case "fs.mkdir":
		logf("%s mkdir %s", s.device, p.Path)
		return true, fsops.Mkdir(roots, p.Path)
	case "fs.create":
		logf("%s create %s", s.device, p.Path)
		return true, fsops.Create(roots, p.Path)
	case "fs.rename":
		logf("%s rename %s → %s", s.device, p.Path, p.To)
		return true, fsops.Rename(roots, p.Path, p.To)
	case "fs.delete":
		logf("%s delete %s", s.device, p.Path)
		return true, fsops.Delete(roots, p.Path)
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
	case "plugins.list":
		return s.a.plugins.List(), nil
	case "devices.list", "devices.pair", "devices.rename", "devices.remove":
		if !s.local {
			return nil, &rpcError{Code: "denied", Msg: "only this Mac's own app manages its devices"}
		}
		return s.a.deviceCall(method, p.Pub, p.Name)
	}
	if m := s.a.plugins.Lookup(method); m != nil {
		if m.Write {
			logf("%s %s", s.device, method)
		}
		return m.Call(&plugin.Ctx{
			Device:  s.device,
			Resolve: func(path string) (string, error) { return fsops.Resolve(roots, path) },
			Log:     logf,
		}, raw)
	}
	return nil, &rpcError{Code: "unknown", Msg: "unknown method " + method}
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
