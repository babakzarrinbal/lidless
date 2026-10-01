package main

// VS Code's Copilot Chat keeps each window's conversations in
// ~/Library/Application Support/Code/User/workspaceStorage/<hash>/chatSessions/
// (workspace.json next to it names the folder). A <id>.jsonl is a log of
// edits to one JSON object: {"kind":0,"v":…} is the start, 1 sets the value
// at path k to v, 2 appends v to the list at k (cut to length i first when i
// is given), 3 deletes k. Older chats are the whole object as <id>.json. The
// object has "customTitle" and "requests": each one's "message.text" is what
// was typed and "response" the parts of the answer.
//
// The phone reads them, and carries one on in a shared terminal by handing its
// transcript to Copilot or Claude (chat.handoff); vscodemirror.go copies that
// terminal's turns back into the chat. They are listed only when the phone
// asks for them (older apps would try to resume them in a terminal).

import (
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

func vscodeStorage() []string {
	home, _ := os.UserHomeDir()
	sup := filepath.Join(home, "Library", "Application Support")
	return []string{
		filepath.Join(sup, "Code", "User", "workspaceStorage"),
		filepath.Join(sup, "Code - Insiders", "User", "workspaceStorage"),
	}
}

// vscodeFolder is the folder a VS Code workspace has open ("" for none, a
// multi-root workspace, or a remote one).
func vscodeFolder(ws string) string {
	b, err := os.ReadFile(filepath.Join(ws, "workspace.json"))
	if err != nil {
		return ""
	}
	var w struct {
		Folder string `json:"folder"`
	}
	if json.Unmarshal(b, &w) != nil {
		return ""
	}
	u, err := url.Parse(w.Folder)
	if err != nil || u.Scheme != "file" || u.Host != "" {
		return ""
	}
	return filepath.Clean(u.Path)
}

// vscodeFiles is every chat file with the folder its window had open.
func vscodeFiles() map[string]string {
	out := map[string]string{}
	for _, root := range vscodeStorage() {
		wss, _ := filepath.Glob(filepath.Join(root, "*"))
		for _, ws := range wss {
			files, _ := filepath.Glob(filepath.Join(ws, "chatSessions", "*.json*"))
			if len(files) == 0 {
				continue
			}
			dir := vscodeFolder(ws)
			if dir == "" {
				continue
			}
			for _, f := range files {
				if strings.HasSuffix(f, ".json") || strings.HasSuffix(f, ".jsonl") {
					out[f] = dir
				}
			}
		}
	}
	return out
}

// vscodeState replays a chat file into its object.
func vscodeState(path string) (map[string]any, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if strings.HasSuffix(path, ".json") {
		var m map[string]any
		return m, json.Unmarshal(b, &m)
	}
	var root any
	for _, l := range strings.Split(string(b), "\n") {
		var e struct {
			Kind int             `json:"kind"`
			K    []any           `json:"k"`
			V    json.RawMessage `json:"v"`
			I    *int            `json:"i"`
		}
		if l == "" || json.Unmarshal([]byte(l), &e) != nil {
			continue
		}
		var v any
		if len(e.V) > 0 {
			json.Unmarshal(e.V, &v)
		}
		switch e.Kind {
		case 0:
			root = v
		case 1:
			root = vscodeEdit(root, e.K, func(any) any { return v })
		case 2:
			add, _ := v.([]any)
			root = vscodeEdit(root, e.K, func(old any) any {
				l, _ := old.([]any)
				if e.I != nil && *e.I >= 0 && *e.I <= len(l) {
					l = l[:*e.I]
				}
				return append(l, add...)
			})
		case 3:
			root = vscodeEdit(root, e.K, func(any) any { return nil })
		}
	}
	m, _ := root.(map[string]any)
	if m == nil {
		return nil, errors.New("not a VS Code chat")
	}
	return m, nil
}

// vscodeEdit replaces the value at path k inside node with f of it.
func vscodeEdit(node any, k []any, f func(any) any) any {
	if len(k) == 0 {
		return f(node)
	}
	switch n := node.(type) {
	case map[string]any:
		if key, ok := k[0].(string); ok {
			n[key] = vscodeEdit(n[key], k[1:], f)
		}
	case []any:
		if i, ok := k[0].(float64); ok && i >= 0 && int(i) < len(n) {
			n[int(i)] = vscodeEdit(n[int(i)], k[1:], f)
		}
	}
	return node
}

func vscodeRequests(m map[string]any) []map[string]any {
	l, _ := m["requests"].([]any)
	out := make([]map[string]any, 0, len(l))
	for _, r := range l {
		if r, ok := r.(map[string]any); ok {
			out = append(out, r)
		}
	}
	return out
}

func vscodeTyped(r map[string]any) string {
	msg, _ := r["message"].(map[string]any)
	s, _ := msg["text"].(string)
	return strings.TrimSpace(s)
}

// vscodeTitles caches each file's title, last prompt and model by its size and
// time: a folder can have hundreds of chats, some of them megabytes.
var vscodeTitles = struct {
	sync.Mutex
	m map[string]vscodeTitle
}{m: map[string]vscodeTitle{}}

type vscodeTitle struct {
	mtime, size          int64
	title, prompt, model string
}

func vscodeTitleOf(c *Conversation) (title, prompt, model string) {
	vscodeTitles.Lock()
	t, ok := vscodeTitles.m[c.path]
	vscodeTitles.Unlock()
	if ok && t.mtime == c.Mtime && t.size == c.Size {
		return t.title, t.prompt, t.model
	}
	t = vscodeTitle{mtime: c.Mtime, size: c.Size}
	if m, err := vscodeState(c.path); err == nil {
		reqs := vscodeRequests(m)
		for _, r := range reqs {
			if p := vscodeTyped(r); p != "" {
				if t.title == "" {
					t.title = p
				}
				t.prompt = p
			}
			if s, _ := r["modelId"].(string); s != "" {
				t.model = s
			}
		}
		if s, _ := m["customTitle"].(string); strings.TrimSpace(s) != "" {
			t.title = s
		}
		t.title, t.prompt = firstLine(t.title), firstLine(t.prompt)
	}
	vscodeTitles.Lock()
	vscodeTitles.m[c.path] = t
	vscodeTitles.Unlock()
	return t.title, t.prompt, t.model
}

// vscodeConversations lists VS Code's chats newest first, at most n of those
// keep takes (keep sees each one's Dir), like [conversations].
func vscodeConversations(n int, keep func(*Conversation) bool) []Conversation {
	var list []Conversation
	for f, dir := range vscodeFiles() {
		st, err := os.Stat(f)
		if err != nil || st.Size() == 0 {
			continue
		}
		id := strings.TrimSuffix(strings.TrimSuffix(filepath.Base(f), ".jsonl"), ".json")
		if !reSessionID.MatchString(id) {
			continue
		}
		list = append(list, Conversation{ID: id, Tool: "vscode", Dir: dir, Mtime: st.ModTime().Unix(), Size: st.Size(), path: f})
	}
	sortConversations(list)
	out := []Conversation{}
	for _, c := range list {
		if len(out) == n {
			break
		}
		if keep != nil && !keep(&c) {
			continue
		}
		c.Title, c.Prompt, c.Model = vscodeTitleOf(&c)
		if c.Title == "" {
			continue // nothing said yet
		}
		out = append(out, c)
	}
	return out
}

// vscodeFind is the chat file with this id and its window's folder.
func vscodeFind(id string) (path, dir string) {
	if !reSessionID.MatchString(id) {
		return "", ""
	}
	for f, d := range vscodeFiles() {
		if b := filepath.Base(f); b == id+".jsonl" || b == id+".json" {
			return f, d
		}
	}
	return "", ""
}

// vscodeTranscript is a chat's items, the last vscodeMax of them, and the
// file's size and time: the phone asks again with them and gets
// {"same": true} until VS Code writes more.
func vscodeTranscript(id string, size, mtime int64, keep func(dir string) bool) (map[string]any, error) {
	path, dir := vscodeFind(id)
	if path == "" || !keep(dir) {
		return nil, errors.New("no such VS Code chat in a shared folder")
	}
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if st.Size() == size && st.ModTime().Unix() == mtime {
		return map[string]any{"same": true}, nil
	}
	m, err := vscodeState(path)
	if err != nil {
		return nil, err
	}
	items := vscodeItems(m)
	if len(items) > vscodeMax {
		items = append([]ChatItem{{K: "note", Text: "Earlier messages are in VS Code"}}, items[len(items)-vscodeMax:]...)
	}
	return map[string]any{"items": items, "size": st.Size(), "mtime": st.ModTime().Unix()}, nil
}

const vscodeMax = 600

// vscodeHandoff writes a chat out as markdown for an agent in a shared
// terminal to carry on (only VS Code can add to the chat itself), and the
// prompt that hands it over.
func vscodeHandoff(id string, keep func(dir string) bool) (map[string]any, error) {
	path, dir := vscodeFind(id)
	if path == "" || !keep(dir) {
		return nil, errors.New("no such VS Code chat in a shared folder")
	}
	m, err := vscodeState(path)
	if err != nil {
		return nil, err
	}
	var b strings.Builder
	title, _ := m["customTitle"].(string)
	b.WriteString("# " + firstLine(title, "VS Code chat") + "\n\nA GitHub Copilot Chat conversation in VS Code, in " + tilde(dir) + ".\n")
	for _, it := range vscodeItems(m) {
		switch it.K {
		case "user":
			b.WriteString("\n## Me\n\n" + it.Text + "\n")
		case "text":
			b.WriteString("\n## Copilot\n\n" + it.Text + "\n")
		case "tool":
			b.WriteString("\n- " + it.Name + ": " + it.Text + "\n")
		case "result":
			if it.Err {
				b.WriteString("  (failed: " + firstLine(it.Text) + ")\n")
			}
		case "note":
			b.WriteString("\n> " + firstLine(it.Text) + "\n")
		}
	}
	s := b.String()
	if len(s) > vscodeHandoffMax { // the newest part: an agent reads the rest from the start if it needs it
		s = "(The start of this conversation is left out.)\n" + s[len(s)-vscodeHandoffMax:]
	}
	home, _ := os.UserHomeDir()
	out := filepath.Join(home, "Library", "Caches", "macremote", "vscode", id+".md")
	if err := os.MkdirAll(filepath.Dir(out), 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(out, []byte(s), 0o600); err != nil {
		return nil, err
	}
	return map[string]any{
		"path": out,
		"prompt": "This carries on a conversation I had in VS Code's Copilot Chat. Read its transcript, " + out +
			", then tell me in a few lines where we left off, and wait for my next message.",
	}, nil
}

const vscodeHandoffMax = 300 << 10

func vscodeItems(m map[string]any) []ChatItem {
	items := []ChatItem{}
	for _, r := range vscodeRequests(m) {
		if p := vscodeTyped(r); p != "" {
			items = append(items, ChatItem{K: "user", Text: p})
		}
		var text strings.Builder
		flush := func() {
			if t := strings.TrimSpace(text.String()); t != "" {
				items = append(items, ChatItem{K: "text", Text: t})
			}
			text.Reset()
		}
		parts, _ := r["response"].([]any)
		for _, p := range parts {
			p, _ := p.(map[string]any)
			kind, _ := p["kind"].(string)
			switch kind {
			case "", "markdownContent":
				text.WriteString(vscodeString(p["value"]))
				if c, ok := p["content"]; ok {
					text.WriteString(vscodeString(c))
				}
			case "toolInvocationSerialized":
				flush()
				items = append(items, vscodeTool(p)...)
			}
		}
		flush()
		res, _ := r["result"].(map[string]any)
		if e, _ := res["errorDetails"].(map[string]any); e != nil {
			if s, _ := e["message"].(string); s != "" {
				items = append(items, ChatItem{K: "note", Text: cut(s)})
			}
		}
	}
	return items
}

// vscodeString is a string, or the "value" of a markdown string object.
func vscodeString(v any) string {
	switch v := v.(type) {
	case string:
		return v
	case map[string]any:
		s, _ := v["value"].(string)
		return s
	}
	return ""
}

var reVSCodeLink = regexp.MustCompile(`\[([^\]]*)\]\(([^)]*)\)`)

// vscodePlain turns VS Code's "Read [](file:///…)" into "Read ~/…".
func vscodePlain(s string) string {
	s = reVSCodeLink.ReplaceAllStringFunc(s, func(l string) string {
		m := reVSCodeLink.FindStringSubmatch(l)
		if m[1] != "" {
			return m[1]
		}
		if u, err := url.Parse(m[2]); err == nil && u.Scheme == "file" {
			p := u.Path
			if u.Fragment != "" {
				p += "#" + u.Fragment
			}
			return tilde(p)
		}
		return m[2]
	})
	return firstLine(strings.ReplaceAll(s, "`", ""))
}

// vscodeTool is one tool call and, once it has finished, its result, named
// the way the phone shows Claude's.
func vscodeTool(p map[string]any) []ChatItem {
	id, _ := p["toolCallId"].(string)
	tool, _ := p["toolId"].(string)
	msg := vscodePlain(vscodeString(p["pastTenseMessage"]))
	if msg == "" {
		msg = vscodePlain(vscodeString(p["invocationMessage"]))
	}
	data, _ := p["toolSpecificData"].(map[string]any)
	name, detail, result, failed := strings.TrimPrefix(tool, "copilot_"), "", "", false
	switch tool {
	case "run_in_terminal":
		name = "Bash"
		cl, _ := data["commandLine"].(map[string]any)
		cmd, _ := cl["original"].(string)
		msg, detail = firstLine(cmd), cut(strings.TrimSpace(cmd))
		out, _ := data["terminalCommandOutput"].(map[string]any)
		s, _ := out["text"].(string)
		result = cut(strings.TrimSpace(reANSI.ReplaceAllString(strings.ReplaceAll(s, "\r", ""), "")))
		st, _ := data["terminalCommandState"].(map[string]any)
		code, _ := st["exitCode"].(float64)
		failed = code != 0
	case "copilot_readFile":
		name = "Read"
	case "copilot_createFile":
		name = "Write"
	case "copilot_replaceString", "copilot_multiReplaceString", "copilot_insertEdit", "copilot_applyPatch", "copilot_editNotebook":
		name = "Edit"
	case "copilot_findTextInFiles", "copilot_searchCodebase":
		name = "Grep"
	case "copilot_findFiles", "copilot_listDirectory":
		name = "Glob"
	case "copilot_fetchWebPage", "fetch_webpage":
		name = "WebFetch"
	case "manage_todo_list":
		name = "TodoWrite"
	case "runSubagent", "search_subagent":
		name = "Agent"
	}
	items := []ChatItem{{K: "tool", ID: id, Name: name, Text: msg, Detail: detail}}
	if done, _ := p["isComplete"].(bool); done && id != "" {
		items = append(items, ChatItem{K: "result", ID: id, Text: result, Err: failed})
	}
	return items
}

var reANSI = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07`)
