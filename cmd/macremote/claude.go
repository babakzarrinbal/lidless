package main

// What the phone lists around a Claude session: the folder's earlier
// conversations (to resume or read) and the slash commands it can type.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	listHead = 64 << 10  // the first message is in here
	listTail = 256 << 10 // Claude re-appends the title often, so it is in here
	listMax  = 60
)

type Conversation struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Prompt  string `json:"prompt,omitempty"` // the last thing typed
	Mtime   int64  `json:"mtime"`
	Size    int64  `json:"size"`
	Tool    string `json:"tool,omitempty"` // "copilot"; Claude's leave it out
	Running bool   `json:"running"`        // a Claude process has it open
	Term    uint32 `json:"term,omitempty"` // …in this agent's terminal
	Dir     string `json:"dir,omitempty"`  // the folder it ran in (recent list only)
	path    string
}

// claudeProjectDir is where Claude Code keeps a folder's transcripts.
func claudeProjectDir(dir string) string {
	home, _ := os.UserHomeDir()
	enc := regexp.MustCompile(`[^a-zA-Z0-9]`).ReplaceAllString(filepath.Clean(dir), "-")
	return filepath.Join(home, ".claude", "projects", enc)
}

// claudeRunning maps the session id of each live Claude process to its pid.
func claudeRunning() map[string]int {
	home, _ := os.UserHomeDir()
	files, _ := filepath.Glob(filepath.Join(home, ".claude", "sessions", "*.json"))
	out := map[string]int{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var s struct {
			PID       int    `json:"pid"`
			SessionID string `json:"sessionId"`
		}
		if json.Unmarshal(b, &s) != nil || s.SessionID == "" || s.PID <= 0 {
			continue
		}
		if err := syscall.Kill(s.PID, 0); err == nil || err == syscall.EPERM {
			out[s.SessionID] = s.PID
		}
	}
	return out
}

// stopClaude quits the Claude process that has conversation sid open (a
// terminal or an editor on the Mac), so the phone can take it over without
// two Claudes writing to one conversation.
func stopClaude(sid string) error {
	if !reSessionID.MatchString(sid) {
		return errors.New("not a conversation id")
	}
	pid := claudeRunning()[sid]
	if pid == 0 {
		return nil // already gone
	}
	out, _ := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "comm=").Output()
	if !strings.Contains(strings.ToLower(string(out)), "claude") {
		return errors.New("the process on that conversation is not Claude; quit it on the Mac")
	}
	if !quitClaude(pid, 5*time.Second) {
		return errors.New("Claude on the Mac is still running; quit it there")
	}
	return nil
}

// parents maps every process to its parent.
func parents() map[int]int {
	out, err := exec.Command("ps", "-A", "-o", "pid=,ppid=").Output()
	m := map[int]int{}
	if err != nil {
		return m
	}
	for _, l := range strings.Split(string(out), "\n") {
		f := strings.Fields(l)
		if len(f) == 2 {
			c, _ := strconv.Atoi(f[0])
			p, _ := strconv.Atoi(f[1])
			m[c] = p
		}
	}
	return m
}

func chatSessions(dir string, terms []*Term) ([]Conversation, error) {
	files, err := filepath.Glob(filepath.Join(claudeProjectDir(dir), "*.jsonl"))
	if err != nil {
		return nil, err
	}
	in := func(c *Conversation) bool { return c.Dir == dir }
	return mergeConversations(conversations(files, terms, listMax, nil), copilotConversations(terms, listMax, in), listMax), nil
}

// mergeConversations is Claude's and Copilot's conversations together,
// newest first, at most n.
func mergeConversations(a, b []Conversation, n int) []Conversation {
	out := append(a, b...)
	sortConversations(out)
	if len(out) > n {
		out = out[:n]
	}
	return out
}

func sortConversations(l []Conversation) {
	sort.SliceStable(l, func(i, j int) bool { return l[i].Mtime > l[j].Mtime })
}

// termOf is the agent's terminal that process pid runs in (0: elsewhere).
func termOf(pid int, terms []*Term) uint32 {
	shells := map[int]uint32{}
	for _, t := range terms {
		if t.cmd != nil && t.cmd.Process != nil {
			shells[t.cmd.Process.Pid] = t.ID
		}
	}
	pp := parents()
	for p, n := pp[pid], 0; p > 1 && n < 20; p, n = pp[p], n+1 {
		if id, ok := shells[p]; ok {
			return id
		}
	}
	return 0
}

// chatRecent is the newest conversations of every folder, each with the
// folder it ran in; keep says which folders the phone may see.
func chatRecent(terms []*Term, n int, keep func(dir string) bool) []Conversation {
	home, _ := os.UserHomeDir()
	files, _ := filepath.Glob(filepath.Join(home, ".claude", "projects", "*", "*.jsonl"))
	claude := conversations(files, terms, n, func(c *Conversation) bool {
		c.Dir = transcriptCwd(c.path)
		return c.Dir != "" && keep(c.Dir)
	})
	return mergeConversations(claude, copilotConversations(terms, n, func(c *Conversation) bool { return keep(c.Dir) }), n)
}

// transcriptCwd is the folder Claude ran in, from the transcript's first
// lines (the project directory's name loses it: "/" and "." both become "-").
func transcriptCwd(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(io.LimitReader(f, listHead))
	sc.Buffer(make([]byte, listHead), listHead)
	for sc.Scan() {
		var e struct {
			Cwd string `json:"cwd"`
		}
		if bytes.Contains(sc.Bytes(), []byte(`"cwd":"`)) && json.Unmarshal(sc.Bytes(), &e) == nil && e.Cwd != "" {
			return e.Cwd
		}
	}
	return ""
}

// conversations lists transcripts newest first, at most n of those keep
// takes, with their titles and whether (and where) Claude has them open.
func conversations(files []string, terms []*Term, n int, keep func(*Conversation) bool) []Conversation {
	running := claudeRunning()
	list := []Conversation{}
	for _, f := range files {
		st, err := os.Stat(f)
		if err != nil || st.Size() == 0 {
			continue
		}
		c := Conversation{ID: strings.TrimSuffix(filepath.Base(f), ".jsonl"), Mtime: st.ModTime().Unix(), Size: st.Size(), path: f}
		list = append(list, c)
	}
	sortConversations(list)
	out := list[:0]
	for _, c := range list {
		if len(out) == n {
			break
		}
		if keep != nil && !keep(&c) {
			continue
		}
		if pid, ok := running[c.ID]; ok {
			c.Running, c.Term = true, termOf(pid, terms)
		}
		c.Title, c.Prompt = conversationTitle(c.path, c.Size)
		out = append(out, c)
	}
	return out
}

// conversationTitle reads Claude's title for a transcript (or, before it has
// one, the first message) and the last prompt typed.
func conversationTitle(path string, size int64) (title, prompt string) {
	f, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer f.Close()
	var e struct {
		Type        string `json:"type"`
		AITitle     string `json:"aiTitle"`
		CustomTitle string `json:"customTitle"`
		Summary     string `json:"summary"`
		LastPrompt  string `json:"lastPrompt"`
	}
	from := max(0, size-listTail)
	buf := make([]byte, size-from)
	if _, err := f.ReadAt(buf, from); err != nil && err != io.EOF {
		return "", ""
	}
	var custom string
	for _, l := range bytes.Split(buf, []byte{'\n'}) {
		if !bytes.Contains(l, []byte(`"type":"`)) || json.Unmarshal(l, &e) != nil {
			continue
		}
		switch e.Type {
		case "ai-title":
			title = e.AITitle
		case "custom-title":
			custom = e.CustomTitle
		case "summary":
			if title == "" {
				title = e.Summary
			}
		case "last-prompt":
			prompt = e.LastPrompt
		}
	}
	if custom != "" {
		title = custom
	}
	if title == "" {
		f.Seek(0, io.SeekStart)
		sc := bufio.NewScanner(io.LimitReader(f, listHead))
		sc.Buffer(make([]byte, listHead), listHead)
		for sc.Scan() && title == "" {
			for _, it := range chatItems(sc.Bytes()) {
				if it.K == "user" {
					title = it.Text
					break
				}
			}
		}
	}
	return clip(firstLine(title), 120), clip(firstLine(prompt), 200)
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

type SlashCommand struct {
	Name string `json:"name"` // without the slash
	Desc string `json:"desc"`
	Src  string `json:"src"` // built-in, user, project, skill
}

// The commands each CLI knows by itself; custom ones are read from disk.
var builtinCommands = map[string][][2]string{
	"claude": {
		{"add-dir", "Add a working directory"},
		{"agents", "Manage subagents"},
		{"clear", "Start a new conversation"},
		{"compact", "Summarise the conversation to free context"},
		{"config", "Open settings"},
		{"context", "Show what fills the context window"},
		{"cost", "Show this session's cost and duration"},
		{"doctor", "Check the installation"},
		{"exit", "Quit Claude Code"},
		{"export", "Export the conversation"},
		{"help", "Show help"},
		{"hooks", "Manage hooks"},
		{"init", "Write a CLAUDE.md for this project"},
		{"login", "Sign in"},
		{"logout", "Sign out"},
		{"mcp", "Manage MCP servers"},
		{"memory", "Edit memory files"},
		{"model", "Choose the model"},
		{"permissions", "Manage tool permissions"},
		{"plan", "Switch to plan mode"},
		{"resume", "Resume an earlier conversation"},
		{"review", "Review a pull request"},
		{"rewind", "Go back to an earlier point"},
		{"status", "Show version, model and account"},
		{"todos", "Show the todo list"},
		{"usage", "Show plan usage limits"},
	},
	"copilot": {
		{"add-dir", "Add a directory Copilot may use"},
		{"agent", "Pick a custom agent"},
		{"clear", "Start a new conversation"},
		{"compact", "Summarise the conversation to free context"},
		{"context", "Show context window use"},
		{"cwd", "Change the working directory"},
		{"delegate", "Hand the task to the Copilot coding agent"},
		{"exit", "Quit"},
		{"feedback", "Send feedback"},
		{"help", "Show help"},
		{"login", "Sign in"},
		{"logout", "Sign out"},
		{"mcp", "Manage MCP servers"},
		{"model", "Choose the model"},
		{"reset-allowed-tools", "Forget tool approvals"},
		{"resume", "Resume an earlier session"},
		{"session", "Show session info"},
		{"share", "Share the session"},
		{"theme", "Change the theme"},
		{"usage", "Show usage"},
	},
}

func chatCommands(dir, kind string) []SlashCommand {
	if kind != "copilot" {
		kind = "claude"
	}
	home, _ := os.UserHomeDir()
	seen := map[string]bool{}
	var out []SlashCommand
	add := func(c SlashCommand) {
		if c.Name != "" && !seen[c.Name] {
			seen[c.Name] = true
			out = append(out, c)
		}
	}
	base := map[string]string{"claude": ".claude", "copilot": ".copilot"}[kind]
	// Project ones first: they win over the user's of the same name.
	for _, root := range []struct{ dir, src string }{{dir, "project"}, {home, "user"}} {
		if root.dir == "" {
			continue
		}
		cmdDir := filepath.Join(root.dir, base, "commands")
		filepath.WalkDir(cmdDir, func(p string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() || !strings.HasSuffix(p, ".md") {
				return nil
			}
			rel, _ := filepath.Rel(cmdDir, strings.TrimSuffix(p, ".md"))
			name, desc := frontmatter(p)
			if name == "" {
				name = strings.ReplaceAll(rel, string(filepath.Separator), ":")
			}
			add(SlashCommand{Name: name, Desc: desc, Src: root.src})
			return nil
		})
		skills, _ := filepath.Glob(filepath.Join(root.dir, base, "skills", "*", "SKILL.md"))
		for _, p := range skills {
			name, desc := frontmatter(p)
			if name == "" {
				name = filepath.Base(filepath.Dir(p))
			}
			add(SlashCommand{Name: name, Desc: desc, Src: "skill"})
		}
	}
	for _, b := range builtinCommands[kind] {
		add(SlashCommand{Name: b[0], Desc: b[1], Src: "built-in"})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// frontmatter reads name and description from a markdown file's front
// matter, or takes the first line of text as the description.
func frontmatter(path string) (name, desc string) {
	f, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer f.Close()
	sc := bufio.NewScanner(io.LimitReader(f, 16<<10))
	in := false
	for n := 0; sc.Scan(); n++ {
		l := strings.TrimSpace(sc.Text())
		switch {
		case n == 0 && l == "---":
			in = true
		case in && l == "---":
			in = false
			if desc != "" {
				return name, clip(desc, 160)
			}
		case in:
			k, v, ok := strings.Cut(l, ":")
			v = strings.Trim(strings.TrimSpace(v), `"'`)
			if ok && k == "name" {
				name = v
			} else if ok && k == "description" {
				desc = v
			}
		case l != "" && !strings.HasPrefix(l, "#"):
			return name, clip(l, 160)
		case strings.HasPrefix(l, "#") && desc == "":
			desc = strings.TrimSpace(strings.TrimLeft(l, "#"))
		}
	}
	return name, clip(desc, 160)
}
