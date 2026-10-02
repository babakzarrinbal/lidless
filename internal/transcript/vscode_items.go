package transcript

// Reading one VS Code chat file (vscode.go has the format): replaying its
// edits into the chat object, and turning its requests into chat items for
// the handoff.

import (
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"regexp"
	"strings"
)

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
