package transcript

// Claude Code's own transcript for a terminal (or Copilot's: copilot.go),
// turned into chat items for the phone. Claude writes ~/.claude/sessions/<pid>.json (its session id) and
// ~/.claude/projects/<dir>/<session id>.jsonl (one JSON entry per line); the
// agent finds the Claude process under the terminal's shell and reads that
// file from a byte offset, so the phone only ever asks for what is new.

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"uniai/internal/usage"
)

const (
	chatTail  = 1536 << 10 // first read: this much of the end of the file
	chatChunk = 2 << 20    // later reads: at most this much at a time
	chatPage  = 512 << 10  // scrolling back: this much before what the phone has
	chatText  = 6 << 10    // tool details and results are cut to this
)

type ChatItem struct {
	K      string `json:"k"` // user, text, tool, result, note
	ID     string `json:"id,omitempty"`
	Name   string `json:"name,omitempty"`
	Text   string `json:"text,omitempty"`
	Detail string `json:"detail,omitempty"`
	Err    bool   `json:"err,omitempty"`
}

// claudeTranscript finds the transcript of a Claude process running under pid.
func claudeTranscript(pid int) string {
	home, _ := os.UserHomeDir()
	out, err := exec.Command("ps", "-A", "-o", "pid=,ppid=").Output()
	if err != nil {
		return ""
	}
	kids := map[int][]int{}
	for _, l := range strings.Split(string(out), "\n") {
		f := strings.Fields(l)
		if len(f) != 2 {
			continue
		}
		c, _ := strconv.Atoi(f[0])
		p, _ := strconv.Atoi(f[1])
		kids[p] = append(kids[p], c)
	}
	for q := kids[pid]; len(q) > 0; q = q[1:] {
		b, err := os.ReadFile(filepath.Join(home, ".claude", "sessions", strconv.Itoa(q[0])+".json"))
		if err != nil {
			q = append(q, kids[q[0]]...)
			continue
		}
		var s struct {
			SessionID string `json:"sessionId"`
		}
		if json.Unmarshal(b, &s) != nil || s.SessionID == "" || strings.ContainsAny(s.SessionID, "/.") {
			continue
		}
		m, _ := filepath.Glob(filepath.Join(home, ".claude", "projects", "*", s.SessionID+".jsonl"))
		if len(m) > 0 {
			return m[0]
		}
	}
	return ""
}

// ChatRead returns the chat items after byte offset from (0: the last part of
// the transcript) and the offset to ask from next time. had is the transcript
// the phone read last; when Claude has moved on to another one, it starts over.
func ChatRead(t *Terminal, from int64, had string) (map[string]any, error) {
	copilot := t.Kind == "copilot"
	path, name, parse := chatSource(t)
	if path == "" {
		return map[string]any{"path": "", "next": 0, "items": []ChatItem{}}, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	size := st.Size()
	reset := from <= 0 || from > size || had != name
	if reset {
		from = max(0, size-chatTail)
	}
	buf := make([]byte, min(size-from, chatChunk))
	if _, err := f.ReadAt(buf, from); err != nil && err != io.EOF {
		return nil, err
	}
	if reset && from > 0 { // started mid-line
		i := bytes.IndexByte(buf, '\n')
		if i < 0 {
			buf = nil
		} else {
			buf, from = buf[i+1:], from+int64(i+1)
		}
	}
	end := bytes.LastIndexByte(buf, '\n') + 1 // whole lines only
	if end == 0 && len(buf) == chatChunk {    // one huge line: skip it
		end = len(buf)
	}
	items := []ChatItem{}
	var ctx *chatContext
	for _, l := range bytes.Split(buf[:end], []byte{'\n'}) {
		items = append(items, parse(l)...)
		if c := lineContext(l); c != nil && !copilot {
			ctx = c
		}
	}
	out := map[string]any{"path": name, "next": from + int64(end), "reset": reset, "items": items}
	if reset {
		out["start"] = from // where the phone's items begin: chat.older reads before it
	}
	if copilot {
		return out, nil
	}
	// Claude's status line knows the real window size; the transcript is the
	// fallback (and is newer when Claude has answered since).
	if st := usage.ReadStatus(strings.TrimSuffix(filepath.Base(path), ".jsonl")); st != nil {
		if used, size := st.ContextWindow.Used(); size > 0 {
			c := &chatContext{Tokens: used, Size: size, Model: st.Model.DisplayName}
			if ctx != nil && ctx.Tokens != used {
				c.Tokens = ctx.Tokens
			}
			ctx = c
		}
	}
	if ctx != nil {
		if ctx.Size == 0 {
			ctx.Size = 200_000
			if ctx.Tokens > ctx.Size || strings.Contains(ctx.Model, "[1m]") {
				ctx.Size = 1_000_000
			}
		}
		out["ctx"] = ctx
	}
	out["used"] = usage.TokenLedger.ChatTokens(path)
	return out, nil
}

// chatSource is the terminal's transcript, the name the phone knows it by, and
// how to read its lines.
func chatSource(t *Terminal) (path, name string, parse func([]byte) []ChatItem) {
	if t.Kind == "copilot" {
		path = copilotTranscript(t.Pid)
		// Every Copilot conversation is events.jsonl: its folder's name.
		return path, filepath.Base(filepath.Dir(path)) + ".jsonl", copilotItems
	}
	path = claudeTranscript(t.Pid)
	// The file's name tells the phone when Claude moved to another conversation.
	return path, filepath.Base(path), chatItems
}

// ChatOlder returns the chat items just before byte offset before (where the
// phone's earliest item begins), for scrolling back to the conversation's
// start, and where they begin (0: the start). had is the transcript the phone
// shows; another one returns nothing.
func ChatOlder(t *Terminal, before int64, had string) (map[string]any, error) {
	path, name, parse := chatSource(t)
	if path == "" || name != had {
		return map[string]any{"path": name, "start": before, "items": []ChatItem{}}, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	items, start, err := olderItems(f, min(before, st.Size()), parse)
	if err != nil {
		return nil, err
	}
	return map[string]any{"path": name, "start": start, "items": items}, nil
}

// olderItems parses the whole lines in the page before offset before. A line
// longer than a page gives nothing (its pieces don't parse) but the next call
// goes on before it.
func olderItems(f io.ReaderAt, before int64, parse func([]byte) []ChatItem) ([]ChatItem, int64, error) {
	items := []ChatItem{}
	if before <= 0 {
		return items, 0, nil
	}
	from := max(0, before-chatPage)
	buf := make([]byte, before-from)
	if _, err := f.ReadAt(buf, from); err != nil && err != io.EOF {
		return nil, 0, err
	}
	if from > 0 { // started mid-line: from the next one (buf ends with a line's newline)
		i := bytes.IndexByte(buf[:len(buf)-1], '\n')
		if i < 0 {
			return items, from, nil
		}
		buf, from = buf[i+1:], from+int64(i+1)
	}
	for _, l := range bytes.Split(buf, []byte{'\n'}) {
		items = append(items, parse(l)...)
	}
	return items, from, nil
}

type chatContext struct {
	Tokens int64  `json:"tokens"`
	Size   int64  `json:"size"`
	Model  string `json:"model,omitempty"`
}

// lineContext is how full the context window was at an assistant answer:
// everything the model read for it.
func lineContext(l []byte) *chatContext {
	if !bytes.Contains(l, []byte(`"usage"`)) || !bytes.Contains(l, []byte(`"assistant"`)) {
		return nil
	}
	var e struct {
		Type        string `json:"type"`
		IsSidechain bool   `json:"isSidechain"`
		Message     struct {
			Model string `json:"model"`
			Usage *struct {
				Input         int64 `json:"input_tokens"`
				CacheCreation int64 `json:"cache_creation_input_tokens"`
				CacheRead     int64 `json:"cache_read_input_tokens"`
			} `json:"usage"`
		} `json:"message"`
	}
	if json.Unmarshal(l, &e) != nil || e.Type != "assistant" || e.IsSidechain || e.Message.Usage == nil || e.Message.Model == "<synthetic>" {
		return nil
	}
	u := e.Message.Usage
	if n := u.Input + u.CacheCreation + u.CacheRead; n > 0 {
		return &chatContext{Tokens: n, Model: e.Message.Model}
	}
	return nil
}

var (
	reReminder = regexp.MustCompile(`(?s)<system-reminder>.*?</system-reminder>`)
	reTag      = regexp.MustCompile(`(?s)<([a-z-]+)>(.*?)</[a-z-]+>`)
)

func chatItems(line []byte) []ChatItem {
	var e struct {
		Type             string          `json:"type"`
		Subtype          string          `json:"subtype"`
		IsMeta           bool            `json:"isMeta"`
		IsSidechain      bool            `json:"isSidechain"`
		IsCompactSummary bool            `json:"isCompactSummary"`
		Operation        string          `json:"operation"` // queue-operation: enqueue, dequeue, remove
		Content          json.RawMessage `json:"content"`   // queue-operation: the queued text
		Attachment       struct {
			Type   string          `json:"type"`
			Prompt json.RawMessage `json:"prompt"`
			Origin struct {
				Kind string `json:"kind"`
			} `json:"origin"`
		} `json:"attachment"`
		Message struct {
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if len(line) == 0 || json.Unmarshal(line, &e) != nil || e.IsMeta || e.IsSidechain || e.IsCompactSummary {
		return nil
	}
	switch e.Type {
	case "system":
		if e.Subtype == "compact_boundary" {
			return []ChatItem{{K: "note", Text: "Conversation compacted"}}
		}
		return nil
	case "queue-operation":
		// A message typed while Claude works waits in a queue: "queued" shows
		// it as pending, "unqueue" takes it off once it is sent or dropped.
		var s string
		json.Unmarshal(e.Content, &s)
		s = strings.TrimSpace(s)
		if e.Operation == "enqueue" {
			if s == "" || strings.HasPrefix(s, "<") { // hand-backs and notifications
				return nil
			}
			return []ChatItem{{K: "queued", Text: s}}
		}
		return []ChatItem{{K: "unqueue", Text: s}}
	case "attachment":
		// A queued message Claude took in mid-turn.
		a := e.Attachment
		if a.Type != "queued_command" || a.Origin.Kind != "human" {
			return nil
		}
		var s string
		if json.Unmarshal(a.Prompt, &s) != nil {
			var blocks []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}
			json.Unmarshal(a.Prompt, &blocks)
			var parts []string
			for _, b := range blocks {
				if b.Type == "text" {
					parts = append(parts, b.Text)
				}
			}
			s = strings.Join(parts, "\n")
		}
		return userText(s)
	case "user", "assistant":
	default:
		return nil
	}
	var s string
	if json.Unmarshal(e.Message.Content, &s) == nil {
		return userText(s)
	}
	var blocks []struct {
		Type      string          `json:"type"`
		Text      string          `json:"text"`
		ID        string          `json:"id"`
		Name      string          `json:"name"`
		Input     json.RawMessage `json:"input"`
		ToolUseID string          `json:"tool_use_id"`
		Content   json.RawMessage `json:"content"`
		IsError   bool            `json:"is_error"`
	}
	if json.Unmarshal(e.Message.Content, &blocks) != nil {
		return nil
	}
	var out []ChatItem
	for _, b := range blocks {
		switch {
		case b.Type == "text" && e.Type == "assistant":
			if t := strings.TrimSpace(b.Text); t != "" {
				out = append(out, ChatItem{K: "text", Text: t})
			}
		case b.Type == "text":
			out = append(out, userText(b.Text)...)
		case b.Type == "image" && e.Type == "user":
			out = append(out, ChatItem{K: "user", Text: "[image]"})
		case b.Type == "tool_use":
			sum, detail := toolSummary(b.Name, b.Input)
			out = append(out, ChatItem{K: "tool", ID: b.ID, Name: b.Name, Text: sum, Detail: detail})
		case b.Type == "tool_result":
			out = append(out, ChatItem{K: "result", ID: b.ToolUseID, Text: cut(resultText(b.Content)), Err: b.IsError})
		}
	}
	return out
}

// userText turns a typed message into a chat item; the tags Claude Code
// wraps around slash commands and ! shell commands become short notes.
func userText(s string) []ChatItem {
	s = strings.TrimSpace(reReminder.ReplaceAllString(s, ""))
	if s == "" {
		return nil
	}
	if !strings.HasPrefix(s, "<") {
		return []ChatItem{{K: "user", Text: s}}
	}
	tags := map[string]string{}
	for _, m := range reTag.FindAllStringSubmatch(s, -1) {
		tags[m[1]] = strings.TrimSpace(m[2])
	}
	switch {
	case tags["command-name"] != "":
		return []ChatItem{{K: "note", Text: strings.TrimSpace(tags["command-name"] + " " + tags["command-args"])}}
	case tags["bash-input"] != "":
		return []ChatItem{{K: "user", Text: "! " + tags["bash-input"]}}
	case tags["local-command-stdout"] != "", tags["bash-stdout"] != "", tags["bash-stderr"] != "":
		t := strings.TrimSpace(tags["local-command-stdout"] + tags["bash-stdout"] + "\n" + tags["bash-stderr"])
		return []ChatItem{{K: "note", Text: cut(t)}}
	case len(tags) > 0:
		return nil
	}
	return []ChatItem{{K: "user", Text: s}}
}

func resultText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	json.Unmarshal(raw, &parts)
	var b strings.Builder
	for _, p := range parts {
		switch p.Type {
		case "text":
			b.WriteString(p.Text)
			b.WriteByte('\n')
		case "image":
			b.WriteString("[image]\n")
		}
	}
	return strings.TrimSpace(b.String())
}

// toolSummary picks the one-line summary and the expandable detail of a call.
func toolSummary(name string, raw json.RawMessage) (string, string) {
	var in map[string]any
	json.Unmarshal(raw, &in)
	str := func(k string) string { s, _ := in[k].(string); return s }
	switch name {
	case "Bash":
		return firstLine(str("description"), str("command")), cut(str("command"))
	case "Read", "Write", "NotebookEdit":
		return tilde(str("file_path")), cut(str("content"))
	case "Edit":
		return tilde(str("file_path")), cut(diff(str("old_string"), str("new_string")))
	case "MultiEdit":
		var d []string
		if es, ok := in["edits"].([]any); ok {
			for _, e := range es {
				m, _ := e.(map[string]any)
				o, _ := m["old_string"].(string)
				n, _ := m["new_string"].(string)
				d = append(d, diff(o, n))
			}
		}
		return tilde(str("file_path")), cut(strings.Join(d, "\n"))
	case "Grep", "Glob":
		return firstLine(str("pattern") + " " + tilde(str("path"))), ""
	case "WebFetch":
		return str("url"), str("prompt")
	case "WebSearch":
		return str("query"), ""
	case "Task", "Agent":
		return firstLine(str("description")), cut(str("prompt"))
	case "TodoWrite":
		var b strings.Builder
		if ts, ok := in["todos"].([]any); ok {
			for _, t := range ts {
				m, _ := t.(map[string]any)
				mark := map[any]string{"completed": "☑", "in_progress": "▸"}[m["status"]]
				if mark == "" {
					mark = "☐"
				}
				c, _ := m["content"].(string)
				b.WriteString(mark + " " + c + "\n")
			}
		}
		return "Todo list", strings.TrimSpace(b.String())
	}
	j, _ := json.MarshalIndent(in, "", "  ")
	return "", cut(string(j))
}

func diff(old, new string) string {
	var b strings.Builder
	for _, l := range strings.Split(old, "\n") {
		b.WriteString("- " + l + "\n")
	}
	for _, l := range strings.Split(new, "\n") {
		b.WriteString("+ " + l + "\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

func firstLine(ss ...string) string {
	for _, s := range ss {
		if s = strings.TrimSpace(s); s != "" {
			l, _, _ := strings.Cut(s, "\n")
			return l
		}
	}
	return ""
}

func tilde(p string) string {
	if h, _ := os.UserHomeDir(); h != "" && strings.HasPrefix(p, h) {
		return "~" + p[len(h):]
	}
	return p
}

func cut(s string) string {
	if len(s) <= chatText {
		return s
	}
	i := chatText
	for i > 0 && s[i]&0xC0 == 0x80 { // not mid-rune
		i--
	}
	return s[:i] + "\n… " + strconv.Itoa(len(s)-i) + " more bytes"
}
