package usage

// Tokens used, per account and per conversation, for Claude Code and Copilot
// CLI, read from their own session files: nothing is asked of any server.
//
// Claude writes every answer's usage into its transcripts; an answer is
// counted once (resumed and forked conversations copy earlier answers into a
// new file) and goes to the account signed in when it was written. Copilot
// writes a session's running totals when the session ends; what grew since
// the session's previous end is counted.
//
// The ledger only grows: a transcript Claude cleans up later stays counted.
// A reset keeps the total at that moment as the baseline.

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"hash/fnv"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"uniai/internal/config"
)

type tokenSum struct {
	In         int64 `json:"in"`
	Out        int64 `json:"out"`
	CacheRead  int64 `json:"cr"`
	CacheWrite int64 `json:"cw"`
}

func (t tokenSum) Total() int64 { return t.In + t.Out + t.CacheRead + t.CacheWrite }

func (t *tokenSum) add(o tokenSum) {
	t.In += o.In
	t.Out += o.Out
	t.CacheRead += o.CacheRead
	t.CacheWrite += o.CacheWrite
}

func (t tokenSum) minus(o tokenSum) tokenSum {
	return tokenSum{t.In - o.In, t.Out - o.Out, t.CacheRead - o.CacheRead, t.CacheWrite - o.CacheWrite}
}

type ledgerFile struct {
	Off   int64    `json:"off"`
	Sum   tokenSum `json:"sum"`             // this conversation's own tokens
	Accts []string `json:"accts,omitempty"` // the accounts they went to
}

type acctTotals struct {
	Tool    string   `json:"tool"`
	Account string   `json:"account"`
	All     tokenSum `json:"all"`
	Base    tokenSum `json:"base"` // All at the last reset
	Since   int64    `json:"since"`
	ResetAt int64    `json:"resetAt,omitempty"`
	Last    int64    `json:"last"`
}

type acctSwitch struct {
	At    int64  `json:"at"`
	Email string `json:"email"`
}

type ledger struct {
	mu       sync.Mutex             // the state below
	scanning sync.Mutex             // one reader of the session files at a time
	Files    map[string]*ledgerFile `json:"files"`
	Accounts map[string]*acctTotals `json:"accounts"`
	Switches []acctSwitch           `json:"switches"` // Claude sign-ins seen, oldest first
	seen     map[uint64]bool        // Claude answers counted (tokens-seen.bin)
	fresh    []uint64               // …not yet appended to it
	loaded   bool
	at       time.Time // last refresh
	claude   string    // ~/.claude
	copilot  string    // ~/.copilot
	dir      string    // where the ledger lives
}

var TokenLedger = newLedger("", "", "")

func newLedger(claude, copilot, dir string) *ledger {
	home, _ := os.UserHomeDir()
	if claude == "" {
		claude = filepath.Join(home, ".claude")
	}
	if copilot == "" {
		copilot = filepath.Join(home, ".copilot")
	}
	if dir == "" {
		dir = config.SupportDir()
	}
	return &ledger{claude: claude, copilot: copilot, dir: dir}
}

func (l *ledger) load() {
	if l.loaded {
		return
	}
	l.loaded = true
	l.Files, l.Accounts, l.seen = map[string]*ledgerFile{}, map[string]*acctTotals{}, map[uint64]bool{}
	if b, err := os.ReadFile(filepath.Join(l.dir, "tokens.json")); err == nil {
		json.Unmarshal(b, l)
		if l.Files == nil {
			l.Files = map[string]*ledgerFile{}
		}
		if l.Accounts == nil {
			l.Accounts = map[string]*acctTotals{}
		}
	}
	if b, err := os.ReadFile(filepath.Join(l.dir, "tokens-seen.bin")); err == nil {
		for i := 0; i+8 <= len(b); i += 8 {
			l.seen[binary.LittleEndian.Uint64(b[i:])] = true
		}
	}
}

func (l *ledger) save() error {
	os.MkdirAll(l.dir, 0o700)
	if len(l.fresh) > 0 {
		f, err := os.OpenFile(filepath.Join(l.dir, "tokens-seen.bin"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			return err
		}
		b := make([]byte, 8*len(l.fresh))
		for i, h := range l.fresh {
			binary.LittleEndian.PutUint64(b[8*i:], h)
		}
		_, err = f.Write(b)
		f.Close()
		if err != nil {
			return err
		}
		l.fresh = nil
	}
	b, err := json.Marshal(l)
	if err != nil {
		return err
	}
	p := filepath.Join(l.dir, "tokens.json")
	if err := os.WriteFile(p+".tmp", b, 0o600); err != nil {
		return err
	}
	return os.Rename(p+".tmp", p)
}

// refresh reads what was written since the last time, at most every `every`.
// While another refresh runs it returns at once: callers then see what that
// one has counted so far (the first one, over months of transcripts, takes a
// while).
func (l *ledger) refresh(every time.Duration) {
	if !l.scanning.TryLock() {
		return
	}
	defer l.scanning.Unlock()
	l.mu.Lock()
	l.load()
	due := time.Since(l.at) >= every
	changed := false
	if due {
		l.at = time.Now()
		changed = l.noteAccount(claudeAccountEmail(l.claude), time.Now().Unix())
	}
	l.mu.Unlock()
	if !due {
		return
	}
	if l.scanClaude() {
		changed = true
	}
	if l.scanCopilot() {
		changed = true
	}
	if changed {
		l.mu.Lock()
		l.save()
		l.mu.Unlock()
	}
}

func (l *ledger) noteAccount(email string, at int64) bool {
	if email == "" || (len(l.Switches) > 0 && l.Switches[len(l.Switches)-1].Email == email) {
		return false
	}
	l.Switches = append(l.Switches, acctSwitch{at, email})
	return true
}

// claudeAccountAt is who was signed in at t; before the first sign-in seen,
// the first account seen.
func (l *ledger) claudeAccountAt(t int64) string {
	if len(l.Switches) == 0 {
		return "unknown"
	}
	who := l.Switches[0].Email
	for _, s := range l.Switches {
		if s.At > t {
			break
		}
		who = s.Email
	}
	return who
}

func (l *ledger) count(tool, account string, at int64, u tokenSum, f *ledgerFile) {
	key := tool + "|" + account
	a := l.Accounts[key]
	if a == nil {
		a = &acctTotals{Tool: tool, Account: account, Since: at}
		l.Accounts[key] = a
	}
	a.All.add(u)
	if at < a.Since {
		a.Since = at
	}
	if at > a.Last {
		a.Last = at
	}
	f.Sum.add(u)
	for _, x := range f.Accts {
		if x == key {
			return
		}
	}
	f.Accts = append(f.Accts, key)
}

type pendingFile struct {
	path  string
	size  int64
	mtime time.Time
}

// scanClaude reads the transcripts' new answers, oldest file first so an
// answer counts for the conversation that first had it.
func (l *ledger) scanClaude() bool {
	var files []pendingFile
	l.mu.Lock()
	defer l.mu.Unlock()
	filepath.WalkDir(filepath.Join(l.claude, "projects"), func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".jsonl") {
			return nil
		}
		if st, err := d.Info(); err == nil {
			if f := l.Files[p]; f == nil || f.Off != st.Size() {
				files = append(files, pendingFile{p, st.Size(), st.ModTime()})
			}
		}
		return nil
	})
	sort.Slice(files, func(i, j int) bool { return files[i].mtime.Before(files[j].mtime) })
	changed := false
	for _, pf := range files {
		l.mu.Unlock() // let readers in between files
		l.mu.Lock()
		f := l.Files[pf.path]
		if f == nil {
			f = &ledgerFile{}
			l.Files[pf.path] = f
		}
		if pf.size < f.Off { // rewritten: what it had is counted already
			f.Off = pf.size
			changed = true
			continue
		}
		off, err := eachLine(pf.path, f.Off, func(line []byte) {
			id, at, u, ok := claudeAnswer(line)
			if !ok {
				return
			}
			h := fnv.New64a()
			h.Write([]byte(id))
			k := h.Sum64()
			if l.seen[k] {
				return
			}
			l.seen[k], l.fresh = true, append(l.fresh, k)
			l.count("claude", l.claudeAccountAt(at), at, u, f)
		})
		if err == nil && off != f.Off {
			f.Off, changed = off, true
		}
	}
	return changed
}

// eachLine calls fn for every complete line from off on, and returns the
// offset after the last one.
func eachLine(path string, off int64, fn func([]byte)) (int64, error) {
	fh, err := os.Open(path)
	if err != nil {
		return off, err
	}
	defer fh.Close()
	if _, err := fh.Seek(off, io.SeekStart); err != nil {
		return off, err
	}
	r := bufio.NewReaderSize(fh, 256<<10)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil { // the last line may still be being written
			return off, nil
		}
		off += int64(len(line))
		fn(line)
	}
}

func claudeAnswer(line []byte) (id string, at int64, u tokenSum, ok bool) {
	if !bytes.Contains(line, []byte(`"usage"`)) || !bytes.Contains(line, []byte(`"assistant"`)) {
		return
	}
	var e struct {
		Type      string    `json:"type"`
		Timestamp time.Time `json:"timestamp"`
		Message   struct {
			ID    string `json:"id"`
			Model string `json:"model"`
			Usage *struct {
				Input         int64 `json:"input_tokens"`
				Output        int64 `json:"output_tokens"`
				CacheCreation int64 `json:"cache_creation_input_tokens"`
				CacheRead     int64 `json:"cache_read_input_tokens"`
			} `json:"usage"`
		} `json:"message"`
	}
	if json.Unmarshal(line, &e) != nil || e.Type != "assistant" || e.Message.ID == "" || e.Message.Usage == nil || e.Message.Model == "<synthetic>" {
		return
	}
	m := e.Message.Usage
	u = tokenSum{m.Input, m.Output, m.CacheRead, m.CacheCreation}
	if u.Total() == 0 {
		return
	}
	at = e.Timestamp.Unix()
	if e.Timestamp.IsZero() {
		at = time.Now().Unix()
	}
	return e.Message.ID, at, u, true
}

// scanCopilot reads the sessions' end-of-session totals.
func (l *ledger) scanCopilot() bool {
	files, _ := filepath.Glob(filepath.Join(l.copilot, "session-state", "*", "events.jsonl"))
	l.mu.Lock()
	defer l.mu.Unlock()
	changed := false
	for _, p := range files {
		st, err := os.Stat(p)
		f := l.Files[p]
		if err != nil || (f != nil && f.Off == st.Size()) {
			continue
		}
		if f == nil {
			f = &ledgerFile{}
			l.Files[p] = f
		}
		if st.Size() < f.Off {
			f.Off, changed = st.Size(), true
			continue
		}
		who := copilotAccount(l.copilot)
		off, err := eachLine(p, f.Off, func(line []byte) {
			at, total, ok := copilotShutdown(line)
			if !ok {
				return
			}
			d := total.minus(f.Sum) // the totals carry on across a resume
			if d.In < 0 || d.Out < 0 || d.CacheRead < 0 || d.CacheWrite < 0 {
				d = total
				f.Sum = tokenSum{}
			}
			l.count("copilot", who, at, d, f)
		})
		if err == nil && off != f.Off {
			f.Off, changed = off, true
		}
	}
	return changed
}

func copilotShutdown(line []byte) (at int64, u tokenSum, ok bool) {
	if !bytes.Contains(line, []byte(`"session.shutdown"`)) {
		return
	}
	var e struct {
		Type      string    `json:"type"`
		Timestamp time.Time `json:"timestamp"`
		Data      struct {
			ModelMetrics map[string]struct {
				Usage struct {
					Input      int64 `json:"inputTokens"`
					Output     int64 `json:"outputTokens"`
					CacheRead  int64 `json:"cacheReadTokens"`
					CacheWrite int64 `json:"cacheWriteTokens"`
				} `json:"usage"`
			} `json:"modelMetrics"`
		} `json:"data"`
	}
	if json.Unmarshal(line, &e) != nil || e.Type != "session.shutdown" {
		return
	}
	for _, m := range e.Data.ModelMetrics {
		// Copilot's input count includes the cached part.
		in := max(0, m.Usage.Input-m.Usage.CacheRead-m.Usage.CacheWrite)
		u.add(tokenSum{in, m.Usage.Output, m.Usage.CacheRead, m.Usage.CacheWrite})
	}
	at = e.Timestamp.Unix()
	if e.Timestamp.IsZero() {
		at = time.Now().Unix()
	}
	return at, u, true
}

// claudeAccountEmail is who Claude Code is signed in as.
func claudeAccountEmail(claudeDir string) string {
	b, err := os.ReadFile(filepath.Join(filepath.Dir(claudeDir), ".claude.json"))
	if err != nil {
		return ""
	}
	var c struct {
		Account *struct {
			Email string `json:"emailAddress"`
		} `json:"oauthAccount"`
	}
	if json.Unmarshal(b, &c) != nil || c.Account == nil {
		return ""
	}
	return c.Account.Email
}

// copilotAccount is the GitHub login Copilot CLI last signed in with.
func copilotAccount(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, "config.json"))
	if err == nil {
		var lines []string
		for _, s := range strings.Split(string(b), "\n") {
			if !strings.HasPrefix(strings.TrimSpace(s), "//") {
				lines = append(lines, s)
			}
		}
		var c map[string]json.RawMessage
		if json.Unmarshal([]byte(strings.Join(lines, "\n")), &c) == nil {
			for _, k := range []string{"last_logged_in_user", "lastLoggedInUser"} {
				var u struct {
					Login string `json:"login"`
				}
				if json.Unmarshal(c[k], &u) == nil && u.Login != "" {
					return u.Login
				}
			}
		}
	}
	return "GitHub"
}

// tokenTotals is every account's totals, the signed-in ones first.
func (l *ledger) TokenTotals() []map[string]any {
	l.refresh(10 * time.Second)
	l.mu.Lock()
	defer l.mu.Unlock()
	cur := map[string]bool{"claude|" + claudeAccountEmail(l.claude): true, "copilot|" + copilotAccount(l.copilot): true}
	keys := make([]string, 0, len(l.Accounts))
	for k := range l.Accounts {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if cur[keys[i]] != cur[keys[j]] {
			return cur[keys[i]]
		}
		return l.Accounts[keys[i]].Last > l.Accounts[keys[j]].Last
	})
	out := []map[string]any{}
	for _, k := range keys {
		a := l.Accounts[k]
		since := a.Since
		if a.ResetAt > 0 {
			since = a.ResetAt
		}
		u := a.All.minus(a.Base)
		out = append(out, map[string]any{
			"tool": a.Tool, "account": a.Account, "current": cur[k],
			"total": u.Total(), "used": u, "all": a.All.Total(), "since": since, "reset": a.ResetAt > 0, "last": a.Last,
		})
	}
	return out
}

func (l *ledger) Reset(tool, account string) bool {
	l.refresh(0)
	l.mu.Lock()
	defer l.mu.Unlock()
	a := l.Accounts[tool+"|"+account]
	if a == nil {
		return false
	}
	a.Base, a.ResetAt = a.All, time.Now().Unix()
	l.save()
	return true
}

// chatTokens is what one Claude conversation used: its transcript and its
// subagents'.
func (l *ledger) ChatTokens(transcript string) map[string]any {
	l.refresh(5 * time.Second)
	l.mu.Lock()
	defer l.mu.Unlock()
	var sum tokenSum
	accts := []string{}
	have := map[string]bool{}
	take := func(f *ledgerFile) {
		sum.add(f.Sum)
		for _, a := range f.Accts {
			if !have[a] {
				have[a] = true
				accts = append(accts, strings.SplitN(a, "|", 2)[1])
			}
		}
	}
	if f := l.Files[transcript]; f != nil {
		take(f)
	}
	sub := strings.TrimSuffix(transcript, ".jsonl") + string(filepath.Separator)
	for p, f := range l.Files {
		if strings.HasPrefix(p, sub) {
			take(f)
		}
	}
	return map[string]any{"total": sum.Total(), "used": sum, "accounts": accts}
}

// KeepCounting reads new tokens every minute, so a transcript Claude deletes
// later is counted before it goes.
func KeepCounting() {
	go func() {
		for {
			TokenLedger.refresh(0)
			time.Sleep(time.Minute)
		}
	}()
}
