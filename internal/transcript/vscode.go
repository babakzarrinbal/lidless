package transcript

// VS Code's Copilot Chat keeps each window's conversations in
// ~/Library/Application Support/Code/User/workspaceStorage/<hash>/ChatSessions/
// (workspace.json next to it names the folder). A <id>.jsonl is a log of
// edits to one JSON object: {"kind":0,"v":…} is the start, 1 sets the value
// at path k to v, 2 appends v to the list at k (cut to length i first when i
// is given), 3 deletes k. Older chats are the whole object as <id>.json. The
// object has "customTitle" and "requests": each one's "message.text" is what
// was typed and "response" the parts of the answer (vscode_items.go reads
// it). A window without a folder keeps its chats in
// globalStorage/emptyWindowChatSessions/; they run in the home folder.
//
// "Move here" in the app carries a chat on with Copilot in a shared terminal:
// chat.handoff writes it out as <id>.md (VSCodeHandoff) and Copilot starts
// with a prompt naming that file. So a terminal whose command names <id>.md
// carries chat <id> (the chat lists that terminal), and a Copilot session
// whose first message names it has the chat's title and stands in for the
// chat in the lists (WithVSCode). VS Code's chats are listed only when the app
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

	"uniai/internal/usage"
)

// vscodeUser is VS Code's User folders (stable and Insiders).
func vscodeUser() []string {
	home, _ := os.UserHomeDir()
	sup := filepath.Join(home, "Library", "Application Support")
	return []string{filepath.Join(sup, "Code", "User"), filepath.Join(sup, "Code - Insiders", "User")}
}

// vscodeCache is where chat.handoff writes chats out for Copilot.
func vscodeCache() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Caches", "uniai", "vscode")
}

// reHandoff finds a handed-off chat's id in a command or a prompt.
var reHandoff = regexp.MustCompile(`/uniai/vscode/([0-9a-fA-F-]{36})\.md`)

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
	add := func(dir string, files []string) {
		for _, f := range files {
			if strings.HasSuffix(f, ".json") || strings.HasSuffix(f, ".jsonl") {
				out[f] = dir
			}
		}
	}
	home, _ := os.UserHomeDir()
	for _, u := range vscodeUser() {
		wss, _ := filepath.Glob(filepath.Join(u, "workspaceStorage", "*"))
		for _, ws := range wss {
			if dir := vscodeFolder(ws); dir != "" {
				files, _ := filepath.Glob(filepath.Join(ws, "ChatSessions", "*.json*"))
				add(dir, files)
			}
		}
		files, _ := filepath.Glob(filepath.Join(u, "globalStorage", "emptyWindowChatSessions", "*.json*"))
		add(home, files)
	}
	return out
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

// WithVSCode adds VS Code's chats to list l (Claude's and Copilot's), at most
// n in all. A chat a Copilot session in l carries on is left out: that
// session stands in for it.
func WithVSCode(l []Conversation, terms []*Terminal, n int, keep func(*Conversation) bool) []Conversation {
	moved := map[string]bool{}
	for _, c := range l {
		if c.From != "" {
			moved[c.From] = true
		}
	}
	vs := VSCodeConversations(terms, n, func(c *Conversation) bool { return !moved[c.ID] && (keep == nil || keep(c)) })
	return MergeConversations(l, vs, n)
}

// VSCodeConversations lists VS Code's chats newest first, at most n of those
// keep takes (keep sees each one's Dir), like [conversations]. A chat a
// shared terminal carries on is running in it.
func VSCodeConversations(terms []*Terminal, n int, keep func(*Conversation) bool) []Conversation {
	carried := map[string]uint32{}
	for _, t := range terms {
		if m := reHandoff.FindStringSubmatch(t.Run); m != nil {
			carried[m[1]] = t.ID
		}
	}
	var list []Conversation
	for f, dir := range vscodeFiles() {
		st, err := os.Stat(f)
		if err != nil || st.Size() == 0 {
			continue
		}
		id := strings.TrimSuffix(strings.TrimSuffix(filepath.Base(f), ".jsonl"), ".json")
		if !usage.ReSessionID.MatchString(id) {
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
		if t, ok := carried[c.ID]; ok {
			c.Running, c.Term = true, t
		}
		out = append(out, c)
	}
	return out
}

// vscodeFind is the chat file with this id and its window's folder.
func vscodeFind(id string) (path, dir string) {
	if !usage.ReSessionID.MatchString(id) {
		return "", ""
	}
	for f, d := range vscodeFiles() {
		if b := filepath.Base(f); b == id+".jsonl" || b == id+".json" {
			return f, d
		}
	}
	return "", ""
}

// VSCodeHandoff writes a chat out as markdown for Copilot in a shared
// terminal to carry on (only VS Code can add to the chat itself), and the
// prompt that hands it over.
func VSCodeHandoff(id string, keep func(dir string) bool) (map[string]any, error) {
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
	out := filepath.Join(vscodeCache(), id+".md")
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

// vscodeHandoffTitle is the title of chat id from its handoff file.
func vscodeHandoffTitle(id string) string {
	b, _ := os.ReadFile(filepath.Join(vscodeCache(), id+".md"))
	if t, ok := strings.CutPrefix(firstLine(string(b)), "# "); ok {
		return t
	}
	return "VS Code chat"
}
