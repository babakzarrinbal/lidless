package main

// Carrying a VS Code chat on, back in VS Code. chat.handoff's prompt names
// <id>.md, so a shared terminal whose command holds that path carries on
// chat <id>. Two things follow from it:
//
//   - links.json (next to the handoffs) lists those terminals; the bz-uniai
//     extension (vscode-ext/, installed into VS Code by the agent) opens each
//     one in the window that has its folder, live and typed into there.
//   - Each turn in the terminal (the prompt, then the answer with its tools in
//     short) is added to the chat's file as a request, so VS Code shows the
//     whole conversation when it opens the chat.
//
// VS Code keeps an open chat in memory and edits its file by index, so a turn
// written under it would take the place of VS Code's next one. Nothing is
// written while the chat is open in a window (its chat view or an editor tab,
// as the window's state.vscdb says) or VS Code wrote it in the last 15 s;
// the turns wait. The chat's file is copied next to the handoff before the
// first write.

import (
	"archive/zip"
	"bytes"
	"embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf16"
)

func vscodeCache() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Caches", "macremote", "vscode")
}

var reHandoff = regexp.MustCompile(`/macremote/vscode/([A-Za-z0-9-]{8,64})\.md`)

type vscodeLink struct {
	Chat  string `json:"chat"`
	Term  uint32 `json:"term"`
	Dir   string `json:"dir"`
	Kind  string `json:"kind"`
	Title string `json:"title"`
}

// vscodeMirror is what has been read of one terminal's transcript.
type vscodeMirror struct {
	transcript string
	parse      func([]byte) []ChatItem
	off        int64
	items      []ChatItem
	written    string // the turns last written to the chat, as JSON
	count      int    // how many there were
	failed     string // the last error, logged once
}

// mirrorVSCode runs for the agent's life: every few seconds it lists the
// terminals carrying a VS Code chat on and mirrors their turns.
func (m *Terms) mirrorVSCode() {
	exe, _ := os.Executable()
	mirrors := map[uint32]*vscodeMirror{}
	var last []byte
	for range time.Tick(3 * time.Second) {
		links := []vscodeLink{}
		live := map[uint32]bool{}
		for _, t := range m.all() {
			mm := reHandoff.FindStringSubmatch(t.run)
			if mm == nil || (t.Kind != "claude" && t.Kind != "copilot") {
				continue
			}
			links = append(links, vscodeLink{Chat: mm[1], Term: t.ID, Dir: t.Dir, Kind: t.Kind, Title: t.info().Title})
			live[t.ID] = true
			mr := mirrors[t.ID]
			if mr == nil {
				mr = &vscodeMirror{}
				mirrors[t.ID] = mr
			}
			if err := mr.step(t, mm[1]); err != nil && err.Error() != mr.failed {
				logf("vscode mirror %s: %v", mm[1], err)
				mr.failed = err.Error()
			}
		}
		for id := range mirrors {
			if !live[id] {
				delete(mirrors, id)
			}
		}
		b, _ := json.Marshal(map[string]any{"bin": exe, "links": links})
		if !bytes.Equal(b, last) && writeFileAtomic(filepath.Join(vscodeCache(), "links.json"), b) == nil {
			last = b
		}
	}
}

func writeFileAtomic(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// step reads what the terminal's agent added to its transcript and, when the
// turns changed, writes them to the chat.
func (mr *vscodeMirror) step(t *Term, chat string) error {
	if mr.transcript == "" {
		path, _, parse := chatSource(t)
		if path == "" {
			return nil // the agent has not started yet
		}
		// Kept: should Claude move on to another conversation (/clear), this one
		// is still the one carrying the chat on.
		mr.transcript, mr.parse = path, parse
	}
	f, err := os.Open(mr.transcript)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	b, err := io.ReadAll(io.NewSectionReader(f, mr.off, 64<<20))
	f.Close()
	if err != nil {
		return err
	}
	if i := bytes.LastIndexByte(b, '\n'); i >= 0 {
		for _, l := range bytes.Split(b[:i], []byte("\n")) {
			mr.items = append(mr.items, mr.parse(l)...)
		}
		mr.off += int64(i + 1)
	} else if len(b) == 64<<20 { // one line that long is no turn: past it
		mr.off += int64(len(b))
	}
	turns := vscodeTurns(mr.items, chat, t.Kind)
	if len(turns) == 0 {
		return nil
	}
	if turns[0].Prompt != vscodeContinued {
		// Not the conversation the handoff started (the agent had not written
		// its own yet, and the one found was older): look again next time.
		mr.transcript, mr.off, mr.items = "", 0, nil
		return nil
	}
	j, _ := json.Marshal(turns)
	if string(j) == mr.written {
		return nil
	}
	// Every write repeats the whole answer of the turn in progress: while it
	// grows, wait for the next prompt or for the agent to go quiet.
	if len(turns) == mr.count && time.Since(st.ModTime()) < 20*time.Second {
		return nil
	}
	path, _ := vscodeFind(chat)
	if path == "" || !strings.HasSuffix(path, ".jsonl") {
		return nil // gone, or an old chat VS Code does not log edits to
	}
	if vscodeBusy(path, chat) {
		return nil
	}
	if err := vscodeWriteTurns(path, chat, t.ID, turns); err != nil {
		return err
	}
	mr.written, mr.count = string(j), len(turns)
	return nil
}

const vscodeContinued = "Continue on all devices"

type vscodeTurn struct {
	Prompt string `json:"prompt"`
	Answer string `json:"answer"`
}

// vscodeTurns groups a transcript's items into prompts and their answers, in
// markdown. The first prompt is the handoff's own.
func vscodeTurns(items []ChatItem, chat, kind string) []vscodeTurn {
	var turns []vscodeTurn
	var b strings.Builder
	prev := ""
	flush := func() {
		if len(turns) > 0 {
			turns[len(turns)-1].Answer = strings.TrimSpace(b.String())
		}
		b.Reset()
	}
	for _, it := range items {
		if it.K == "user" {
			flush()
			turns = append(turns, vscodeTurn{Prompt: it.Text})
			prev = ""
			continue
		}
		if len(turns) == 0 {
			continue
		}
		switch it.K {
		case "text":
			b.WriteString("\n\n" + it.Text)
		case "tool":
			if prev != "tool" && prev != "result" {
				b.WriteString("\n")
			}
			b.WriteString("\n- *" + it.Name + "* " + vscodeInline(it.Text))
		case "result":
			if it.Err {
				b.WriteString(" (failed: " + vscodeInline(it.Text) + ")")
			}
		case "note":
			b.WriteString("\n\n> " + firstLine(it.Text))
		}
		if it.K != "result" || it.Err {
			prev = it.K
		}
	}
	flush()
	if len(turns) > 0 && strings.Contains(turns[0].Prompt, "/"+chat+".md") {
		tool := map[string]string{"claude": "Claude Code", "copilot": "Copilot CLI"}[kind]
		turns[0].Prompt = vscodeContinued
		turns[0].Answer = strings.TrimSpace("*This chat carries on in a shared terminal (" + tool +
			"), on all your devices. Its turns are copied here.*\n\n" + turns[0].Answer)
	}
	return turns
}

// vscodeInline is a tool's one-line summary, safe inside markdown.
func vscodeInline(s string) string {
	s = firstLine(s)
	if s == "" {
		return ""
	}
	return "`" + strings.ReplaceAll(clip(s, 200), "`", "'") + "`"
}

// vscodeBusy says the chat may be open in VS Code, or being written.
func vscodeBusy(path, chat string) bool {
	st, err := os.Stat(path)
	if err != nil || time.Since(st.ModTime()) < 15*time.Second {
		return true
	}
	db := filepath.Join(filepath.Dir(filepath.Dir(path)), "state.vscdb")
	if _, err := os.Stat(db); err != nil {
		return true // no way to tell whether the chat is open: leave it alone
	}
	if !reSessionID.MatchString(chat) { // it goes into the query
		return true
	}
	like := []string{chat, base64.StdEncoding.EncodeToString([]byte(chat)), base64.RawURLEncoding.EncodeToString([]byte(chat))}
	q := "select count(*) from ItemTable where (key like 'memento/interactive-session%' or key like 'memento/workbench.parts.editor%' or key like 'memento/workbench.editor%') and (value like '%" +
		strings.Join(like, "%' or value like '%") + "%');"
	out, err := exec.Command("/usr/bin/sqlite3", "-readonly", db, q).Output()
	if err != nil {
		return true // locked while VS Code saves: next time
	}
	return strings.TrimSpace(string(out)) != "0"
}

// vscodeWriteTurns adds the turns the chat lacks and updates the answers that
// grew, appending to VS Code's log of edits. Each turn is a request with a
// requestId of our own; the rest of it is copied from the chat's last request
// VS Code made, so it reads like one of VS Code's own.
func vscodeWriteTurns(path, chat string, term uint32, turns []vscodeTurn) error {
	before, err := os.Stat(path)
	if err != nil {
		return err
	}
	m, err := vscodeState(path)
	if err != nil {
		return err
	}
	reqs := vscodeRequests(m)
	at := map[string]int{}
	var tmpl map[string]any
	for i, r := range reqs {
		id, _ := r["requestId"].(string)
		at[id] = i
		if !strings.HasPrefix(id, "request_lidless-") {
			tmpl = r
		}
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	for i, turn := range turns {
		id := fmt.Sprintf("request_lidless-%d-%d", term, i)
		answer := turn.Answer
		if answer == "" {
			answer = "*…*"
		}
		resp := []any{map[string]any{"value": answer, "supportThemeIcons": false, "supportHtml": false}}
		if k, ok := at[id]; ok {
			if vscodeAnswer(reqs[k]) != answer {
				enc.Encode(map[string]any{"kind": 1, "k": []any{"requests", k, "response"}, "v": resp})
			}
			continue
		}
		enc.Encode(map[string]any{"kind": 2, "k": []any{"requests"}, "v": []any{vscodeRequest(tmpl, id, turn.Prompt, resp)}})
	}
	if out.Len() == 0 {
		return nil
	}
	bak := filepath.Join(vscodeCache(), chat+".jsonl.bak")
	if _, err := os.Stat(bak); os.IsNotExist(err) {
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err := writeFileAtomic(bak, b); err != nil {
			return err
		}
	}
	f, err := os.OpenFile(path, os.O_RDWR|os.O_APPEND, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	if st.Size() != before.Size() || !st.ModTime().Equal(before.ModTime()) {
		return nil // VS Code wrote it meanwhile: the indexes may be off, next time
	}
	if st.Size() > 0 {
		end := make([]byte, 1)
		if _, err := f.ReadAt(end, st.Size()-1); err == nil && end[0] != '\n' {
			out = *bytes.NewBuffer(append([]byte("\n"), out.Bytes()...))
		}
	}
	_, err = f.Write(out.Bytes())
	return err
}

func vscodeAnswer(r map[string]any) string {
	l, _ := r["response"].([]any)
	if len(l) != 1 {
		return ""
	}
	p, _ := l[0].(map[string]any)
	s, _ := p["value"].(string)
	return s
}

func vscodeRequest(tmpl map[string]any, id, prompt string, resp []any) map[string]any {
	now := time.Now().UnixMilli()
	n := len(utf16.Encode([]rune(prompt)))
	lines := strings.Split(prompt, "\n")
	req := map[string]any{
		"requestId":  id,
		"responseId": "response_" + strings.TrimPrefix(id, "request_"),
		"timestamp":  now,
		"message": map[string]any{"text": prompt, "parts": []any{map[string]any{
			"range": map[string]any{"start": 0, "endExclusive": n},
			"editorRange": map[string]any{"startLineNumber": 1, "startColumn": 1, "endLineNumber": len(lines),
				"endColumn": len(utf16.Encode([]rune(lines[len(lines)-1]))) + 1},
			"text": prompt, "kind": "text",
		}}},
		"variableData":      map[string]any{"variables": []any{}},
		"response":          resp,
		"result":            map[string]any{"timings": map[string]any{"totalElapsed": 0}, "metadata": map[string]any{}},
		"modelState":        map[string]any{"value": 1, "completedAt": now},
		"contentReferences": []any{},
		"codeCitations":     []any{},
		"followups":         []any{},
	}
	for _, k := range []string{"agent", "modelId", "modeInfo"} {
		if v, ok := tmpl[k]; ok {
			req[k] = v
		}
	}
	return req
}

//go:embed vscode-ext/package.json vscode-ext/extension.js
var vscodeExt embed.FS

// vscodeExtVSIX packs the extension the way `vsce package` does, and says its
// version.
func vscodeExtVSIX() ([]byte, string, error) {
	pkg, err := vscodeExt.ReadFile("vscode-ext/package.json")
	if err != nil {
		return nil, "", err
	}
	var p struct{ Name, Publisher, Version, DisplayName, Description string }
	if err := json.Unmarshal(pkg, &p); err != nil {
		return nil, "", err
	}
	manifest := `<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="` + p.Name + `" Version="` + p.Version + `" Publisher="` + p.Publisher + `"/>
    <DisplayName>` + xmlText.Replace(p.DisplayName) + `</DisplayName>
    <Description xml:space="preserve">` + xmlText.Replace(p.Description) + `</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0"/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
`
	types := `<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".json" ContentType="application/json"/><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
`
	js, err := vscodeExt.ReadFile("vscode-ext/extension.js")
	if err != nil {
		return nil, "", err
	}
	var buf bytes.Buffer
	z := zip.NewWriter(&buf)
	for _, f := range []struct {
		name string
		b    []byte
	}{{"extension.vsixmanifest", []byte(manifest)}, {"[Content_Types].xml", []byte(types)},
		{"extension/package.json", pkg}, {"extension/extension.js", js}} {
		w, err := z.Create(f.name)
		if err != nil {
			return nil, "", err
		}
		w.Write(f.b)
	}
	if err := z.Close(); err != nil {
		return nil, "", err
	}
	return buf.Bytes(), p.Publisher + "." + p.Name + "-" + p.Version, nil
}

var xmlText = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;")

// vscodeCLIs are the `code` commands of the VS Codes on this Mac.
func vscodeCLIs() []string {
	home, _ := os.UserHomeDir()
	var out []string
	for _, v := range []struct{ app, cli string }{{"Visual Studio Code", "code"}, {"Visual Studio Code - Insiders", "code-insiders"}} {
		for _, root := range []string{"/Applications", filepath.Join(home, "Applications")} {
			cli := filepath.Join(root, v.app+".app", "Contents", "Resources", "app", "bin", v.cli)
			if _, err := os.Stat(cli); err == nil {
				out = append(out, cli)
				break
			}
		}
	}
	return out
}

// vscodeExtInstall puts this agent's bz-uniai extension into each VS Code that
// lacks this version of it (all of them with force), and says what it did.
func vscodeExtInstall(force bool) (string, error) {
	vsix, full, err := vscodeExtVSIX()
	if err != nil {
		return "", err
	}
	clis := vscodeCLIs()
	if len(clis) == 0 {
		return "no VS Code in /Applications", nil
	}
	home, _ := os.UserHomeDir()
	var did []string
	for _, cli := range clis {
		dir := ".vscode"
		if strings.HasSuffix(cli, "insiders") {
			dir = ".vscode-insiders"
		}
		if _, err := os.Stat(filepath.Join(home, dir, "extensions", full)); err == nil && !force {
			continue
		}
		path := filepath.Join(vscodeCache(), full+".vsix")
		if err := writeFileAtomic(path, vsix); err != nil {
			return "", err
		}
		if b, err := exec.Command(cli, "--install-extension", path, "--force").CombinedOutput(); err != nil {
			return "", fmt.Errorf("%s: %v: %s", filepath.Base(cli), err, strings.TrimSpace(string(b)))
		}
		did = append(did, filepath.Base(cli))
	}
	if len(did) == 0 {
		return full + " is already installed", nil
	}
	return "installed " + full + " into " + strings.Join(did, ", "), nil
}

// cmdVSCode installs the extension: `macremote vscode`.
func cmdVSCode(args []string) {
	msg, err := vscodeExtInstall(len(args) > 0 && args[0] == "-force")
	if err != nil {
		die("%v", err)
	}
	fmt.Println(msg)
}
