package main

// GitHub Copilot CLI's sessions, for the phone's chat view and lists. Copilot
// keeps each session in ~/.copilot/session-state/<id>/: workspace.yaml (the
// folder it ran in) and events.jsonl (one event per line: user.message,
// assistant.message, tool.execution_start/complete, …). A running Copilot
// holds inuse.<pid>.lock in its session's folder.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func copilotHome() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".copilot", "session-state")
}

// copilotTranscript finds the events file of a Copilot process running under pid.
func copilotTranscript(pid int) string {
	kids := map[int][]int{}
	for c, p := range parents() {
		kids[p] = append(kids[p], c)
	}
	root := copilotHome()
	for q := kids[pid]; len(q) > 0; q = q[1:] {
		m, _ := filepath.Glob(filepath.Join(root, "*", "inuse."+strconv.Itoa(q[0])+".lock"))
		if len(m) == 0 {
			q = append(q, kids[q[0]]...)
			continue
		}
		p := filepath.Join(filepath.Dir(m[0]), "events.jsonl")
		if _, err := os.Stat(p); err == nil {
			return p
		}
		return ""
	}
	return ""
}

// copilotRunning maps the id of each session a live Copilot holds to its pid.
func copilotRunning() map[string]int {
	m, _ := filepath.Glob(filepath.Join(copilotHome(), "*", "inuse.*.lock"))
	out := map[string]int{}
	for _, f := range m {
		pid, _ := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "inuse."), ".lock"))
		if pid <= 0 {
			continue
		}
		if err := syscall.Kill(pid, 0); err == nil || err == syscall.EPERM {
			out[filepath.Base(filepath.Dir(f))] = pid
		}
	}
	return out
}

// copilotBin finds the real Copilot CLI on the login shell's PATH. VS Code's
// Copilot Chat puts a "copilot" shim on PATH (often ~/.local/bin, ahead of
// Homebrew) that strips only its own folder from PATH and runs "copilot"
// again: when it finds itself (a symlink to it, say) it starts itself until
// the Mac runs out of processes.
func copilotBin(shell string) (string, error) {
	out, _ := exec.Command(shell, "-l", "-c", "which -a copilot").Output()
	shims := 0
	for _, p := range strings.Split(string(out), "\n") {
		if p = strings.TrimSpace(p); !filepath.IsAbs(p) {
			continue
		}
		real, err := filepath.EvalSymlinks(p)
		if err != nil {
			continue
		}
		if copilotShim(real) {
			shims++
			continue
		}
		return p, nil
	}
	if shims > 0 {
		return "", errors.New("only VS Code's copilot shim is on this Mac's PATH, and it loops; install the Copilot CLI: brew install copilot-cli")
	}
	return "", errors.New("GitHub Copilot CLI is not installed on this Mac: brew install copilot-cli")
}

func copilotShim(path string) bool {
	return strings.Contains(path, "github.copilot-chat") || strings.Contains(path, "/copilotCli/")
}

// copilotCommand swaps the bare "copilot" at the start of run for the real
// CLI's path.
func copilotCommand(shell, run string) (string, error) {
	name, rest, _ := strings.Cut(run, " ")
	if name != "copilot" {
		return run, nil
	}
	bin, err := copilotBin(shell)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(shellQuote(bin) + " " + rest), nil
}

func shellQuote(s string) string {
	if !strings.ContainsAny(s, " '\"\\$`!*?&;|<>()[]{}#~") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// copilotCwd is the folder a session ran in, from its workspace.yaml.
func copilotCwd(sessionDir string) string {
	b, err := os.ReadFile(filepath.Join(sessionDir, "workspace.yaml"))
	if err != nil {
		return ""
	}
	for _, l := range strings.Split(string(b), "\n") {
		if v, ok := strings.CutPrefix(l, "cwd:"); ok {
			return strings.Trim(strings.TrimSpace(v), `"'`)
		}
	}
	return ""
}

// copilotConversations lists Copilot's sessions newest first, at most n of
// those keep takes (keep sees each one's Dir), like [conversations].
func copilotConversations(terms []*Term, n int, keep func(*Conversation) bool) []Conversation {
	files, _ := filepath.Glob(filepath.Join(copilotHome(), "*", "events.jsonl"))
	var list []Conversation
	for _, f := range files {
		st, err := os.Stat(f)
		if err != nil || st.Size() == 0 {
			continue
		}
		id := filepath.Base(filepath.Dir(f))
		if !reSessionID.MatchString(id) {
			continue
		}
		list = append(list, Conversation{ID: id, Tool: "copilot", Mtime: st.ModTime().Unix(), Size: st.Size(), path: f})
	}
	sortConversations(list)
	running := copilotRunning()
	out := []Conversation{}
	for _, c := range list {
		if len(out) == n {
			break
		}
		c.Dir = copilotCwd(filepath.Dir(c.path))
		if c.Dir == "" || (keep != nil && !keep(&c)) {
			continue
		}
		if pid, ok := running[c.ID]; ok {
			c.Running, c.Term = true, termOf(pid, terms)
		}
		c.Title, c.Prompt = copilotTitle(c.path)
		if c.Title == "" {
			continue // nothing said yet
		}
		out = append(out, c)
	}
	return out
}

// copilotTitle is the session's title (or else its first message) and the
// last message typed.
func copilotTitle(path string) (title, prompt string) {
	f, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer f.Close()
	var first string
	sc := bufio.NewScanner(io.Reader(f))
	sc.Buffer(make([]byte, 64<<10), 8<<20)
	for sc.Scan() {
		l := sc.Bytes()
		if !bytes.Contains(l, []byte(`"user.message"`)) && !bytes.Contains(l, []byte(`"session.title_changed"`)) {
			continue
		}
		var e copilotEvent
		if json.Unmarshal(l, &e) != nil {
			continue
		}
		switch {
		case e.Type == "session.title_changed" && e.Data.Title != "":
			title = e.Data.Title
		case e.Type == "user.message" && e.Data.Source == "" && strings.TrimSpace(e.Data.Content) != "":
			prompt = strings.TrimSpace(e.Data.Content)
			if first == "" {
				first = prompt
			}
		}
	}
	if title == "" {
		title = first
	}
	return firstLine(title), firstLine(prompt)
}

type copilotEvent struct {
	Type string `json:"type"`
	Data struct {
		Content    string          `json:"content"`
		Source     string          `json:"source"` // set on messages Copilot wrote itself
		Message    string          `json:"message"`
		Title      string          `json:"title"`
		Parent     string          `json:"parentToolCallId"` // a sub-agent's
		ToolCallID string          `json:"toolCallId"`
		ToolName   string          `json:"toolName"`
		Arguments  json.RawMessage `json:"arguments"`
		Success    bool            `json:"success"`
		Result     struct {
			Content json.RawMessage `json:"content"`
		} `json:"result"`
		Error json.RawMessage `json:"error"`
	} `json:"data"`
}

// copilotItems turns one events.jsonl line into chat items.
func copilotItems(line []byte) []ChatItem {
	var e copilotEvent
	if len(line) == 0 || json.Unmarshal(line, &e) != nil || e.Data.Parent != "" {
		return nil
	}
	d := e.Data
	switch e.Type {
	case "user.message":
		if d.Source != "" {
			return nil
		}
		return userText(d.Content)
	case "assistant.message":
		if t := strings.TrimSpace(d.Content); t != "" {
			return []ChatItem{{K: "text", Text: t}}
		}
	case "tool.execution_start":
		if d.ToolName == "report_intent" { // Copilot's status line, not work
			return nil
		}
		name, sum, detail := copilotTool(d.ToolName, d.Arguments)
		return []ChatItem{{K: "tool", ID: d.ToolCallID, Name: name, Text: sum, Detail: detail}}
	case "tool.execution_complete":
		text := resultText(d.Result.Content)
		if !d.Success {
			var s string
			var m struct {
				Message string `json:"message"`
			}
			if json.Unmarshal(d.Error, &s) != nil && json.Unmarshal(d.Error, &m) == nil {
				s = m.Message
			}
			text = strings.TrimSpace(s + "\n" + text)
		}
		return []ChatItem{{K: "result", ID: d.ToolCallID, Text: cut(text), Err: !d.Success}}
	case "session.compaction_complete":
		return []ChatItem{{K: "note", Text: "Conversation compacted"}}
	case "session.error":
		if d.Message != "" {
			return []ChatItem{{K: "note", Text: cut(d.Message)}}
		}
	}
	return nil
}

// copilotTool names a Copilot tool call the way the phone shows Claude's,
// with a one-line summary and the expandable detail.
func copilotTool(name string, raw json.RawMessage) (string, string, string) {
	var in map[string]any
	json.Unmarshal(raw, &in)
	str := func(ks ...string) string {
		for _, k := range ks {
			if s, _ := in[k].(string); s != "" {
				return s
			}
		}
		return ""
	}
	path := tilde(str("path", "file_path"))
	switch name {
	case "bash", "shell", "powershell":
		return "Bash", firstLine(str("description"), str("command")), cut(str("command"))
	case "view", "read":
		return "Read", path, ""
	case "create":
		return "Write", path, cut(str("file_text", "content"))
	case "edit", "str_replace", "str_replace_editor":
		return "Edit", path, cut(diff(str("old_str", "old_string"), str("new_str", "new_string")))
	case "grep", "rg":
		return "Grep", firstLine(str("pattern") + " " + tilde(str("path"))), ""
	case "glob":
		return "Glob", firstLine(str("pattern") + " " + tilde(str("path"))), ""
	case "web_fetch":
		return "WebFetch", str("url"), ""
	}
	j, _ := json.MarshalIndent(in, "", "  ")
	return name, firstLine(str("description", "path", "query", "url", "pattern")), cut(string(j))
}
