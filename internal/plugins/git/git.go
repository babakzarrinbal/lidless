// Package git is the git plugin: the repositories under a workspace root and
// what changed in each. Read-only for now; it runs the git CLI.
package git

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"uniai/internal/plugin"
)

const (
	scanDepth = 3       // folders below the root searched for repositories
	maxRepos  = 50      // stop scanning after this many
	maxDiff   = 1 << 20 // bytes of diff returned; the rest is cut
	maxOut    = 16 << 20
	timeout   = 15 * time.Second
)

// Folders never worth scanning for repositories.
var skip = map[string]bool{
	"node_modules": true, "vendor": true, "Pods": true, "build": true, "dist": true,
	"target": true, "DerivedData": true, "Library": true,
}

func Plugin() plugin.Plugin {
	return plugin.Plugin{
		Name:    "git",
		Desc:    "Git repositories under a folder: status, history, diffs",
		Version: 1,
		Methods: []plugin.Method{
			{
				Name:   "git.repos",
				Desc:   "List the git repositories at or below a folder (3 levels), each with its branch and how many files changed",
				Params: json.RawMessage(`{"type":"object","properties":{"dir":{"type":"string","description":"absolute folder, usually the workspace root"}},"required":["dir"]}`),
				Call:   repos,
			},
			{
				Name:   "git.status",
				Desc:   "Branch, upstream, ahead/behind and changed files of one repository",
				Params: json.RawMessage(`{"type":"object","properties":{"repo":{"type":"string","description":"absolute path of the repository"}},"required":["repo"]}`),
				Call:   status,
			},
			{
				Name:   "git.log",
				Desc:   "Recent commits of one repository, newest first",
				Params: json.RawMessage(`{"type":"object","properties":{"repo":{"type":"string"},"n":{"type":"integer","description":"how many, default 50, at most 200"},"skip":{"type":"integer"},"path":{"type":"string","description":"only commits touching this path"}},"required":["repo"]}`),
				Call:   history,
			},
			{
				Name:   "git.diff",
				Desc:   "Unified diff of uncommitted changes (worktree, or staged), or of one commit",
				Params: json.RawMessage(`{"type":"object","properties":{"repo":{"type":"string"},"path":{"type":"string","description":"only this file, relative to the repository"},"staged":{"type":"boolean"},"commit":{"type":"string","description":"show this commit instead"}},"required":["repo"]}`),
				Call:   diff,
			},
		},
	}
}

// capped keeps the first max bytes written to it and drops the rest.
type capped struct {
	buf bytes.Buffer
	max int
	cut bool
}

func (c *capped) Write(p []byte) (int, error) {
	if room := c.max - c.buf.Len(); len(p) > room {
		c.buf.Write(p[:max(room, 0)])
		c.cut = true
		return len(p), nil
	}
	return c.buf.Write(p)
}

func run(dir string, args ...string) ([]byte, error) {
	b, _, err := runMax(dir, maxOut, args...)
	return b, err
}

// runMax runs git in dir and returns at most limit bytes of stdout, and
// whether it cut some. It never prompts and never takes the index lock, so it
// cannot get in the way of an AI committing. A repository's own config cannot
// run commands through it (fsmonitor, hooks; diff passes --no-textconv).
func runMax(dir string, limit int, args ...string) ([]byte, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	base := []string{"-C", dir, "-c", "core.quotepath=off", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"}
	cmd := exec.CommandContext(ctx, "git", append(base, args...)...)
	cmd.Env = append(os.Environ(), "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
	out := &capped{max: limit}
	var errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = out, &errb
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			msg := strings.TrimSpace(errb.String())
			msg = strings.TrimPrefix(msg, "fatal: ")
			if msg == "" {
				msg = err.Error()
			}
			return nil, false, &plugin.Error{Code: "git", Msg: msg}
		}
		if errors.Is(err, exec.ErrNotFound) {
			return nil, false, &plugin.Error{Code: "nogit", Msg: "git is not installed"}
		}
		return nil, false, err
	}
	return out.buf.Bytes(), out.cut, nil
}

// repoOf resolves a caller's path and checks it is a repository's top level.
func repoOf(c *plugin.Ctx, p string) (string, error) {
	dir, err := c.Resolve(p)
	if err != nil {
		return "", err
	}
	top, err := run(dir, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", &plugin.Error{Code: "norepo", Msg: "not a git repository"}
	}
	// SameFile, not ==: APFS ignores case, so the caller's spelling may differ from git's.
	a, err1 := os.Stat(strings.TrimSpace(string(top)))
	b, err2 := os.Stat(dir)
	if err1 != nil || err2 != nil || !os.SameFile(a, b) {
		return "", &plugin.Error{Code: "norepo", Msg: "not the top folder of a repository"}
	}
	return dir, nil
}

type Repo struct {
	Path    string `json:"path"`
	Rel     string `json:"rel"` // relative to the scanned folder; "." is the folder itself
	Branch  string `json:"branch"`
	Changed int    `json:"changed"`
	Ahead   int    `json:"ahead"`
	Behind  int    `json:"behind"`
}

func repos(c *plugin.Ctx, raw json.RawMessage) (any, error) {
	var p struct {
		Dir string `json:"dir"`
	}
	if err := plugin.Decode(raw, &p); err != nil {
		return nil, err
	}
	root, err := c.Resolve(p.Dir)
	if err != nil {
		return nil, err
	}
	var found []string
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		if len(found) >= maxRepos {
			return
		}
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			found = append(found, dir)
		}
		if depth == scanDepth {
			return
		}
		ents, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range ents {
			n := e.Name()
			if e.IsDir() && !strings.HasPrefix(n, ".") && !skip[n] {
				walk(filepath.Join(dir, n), depth+1)
			}
		}
	}
	walk(root, 0)
	out := make([]Repo, 0, len(found))
	for _, d := range found {
		rel, _ := filepath.Rel(root, d)
		r := Repo{Path: d, Rel: rel}
		if st, err := readStatus(d); err == nil {
			r.Branch, r.Ahead, r.Behind, r.Changed = st.Branch, st.Ahead, st.Behind, len(st.Files)
		}
		out = append(out, r)
	}
	return out, nil
}

type File struct {
	Path     string `json:"path"`
	Orig     string `json:"orig,omitempty"` // renamed or copied from
	Index    string `json:"index"`          // staged: M A D R C T, "." none, "?" untracked
	Work     string `json:"work"`           // worktree: same letters
	Conflict bool   `json:"conflict,omitempty"`
}

type Status struct {
	Branch   string `json:"branch"` // "" when detached
	Commit   string `json:"commit"` // "" before the first commit
	Upstream string `json:"upstream,omitempty"`
	Ahead    int    `json:"ahead"`
	Behind   int    `json:"behind"`
	Files    []File `json:"files"`
}

func status(c *plugin.Ctx, raw json.RawMessage) (any, error) {
	var p struct {
		Repo string `json:"repo"`
	}
	if err := plugin.Decode(raw, &p); err != nil {
		return nil, err
	}
	dir, err := repoOf(c, p.Repo)
	if err != nil {
		return nil, err
	}
	return readStatus(dir)
}

func readStatus(dir string) (*Status, error) {
	b, err := run(dir, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	return parseStatus(b), nil
}

// parseStatus reads `git status --porcelain=v2 --branch -z`.
func parseStatus(b []byte) *Status {
	st := &Status{Files: []File{}}
	recs := strings.Split(string(b), "\x00")
	for i := 0; i < len(recs); i++ {
		r := recs[i]
		if r == "" {
			continue
		}
		switch r[0] {
		case '#':
			f := strings.Fields(r)
			if len(f) < 3 {
				continue
			}
			switch f[1] {
			case "branch.oid":
				if f[2] != "(initial)" {
					st.Commit = f[2]
				}
			case "branch.head":
				if f[2] != "(detached)" {
					st.Branch = f[2]
				}
			case "branch.upstream":
				st.Upstream = f[2]
			case "branch.ab":
				if len(f) == 4 {
					st.Ahead, _ = strconv.Atoi(strings.TrimPrefix(f[2], "+"))
					st.Behind, _ = strconv.Atoi(strings.TrimPrefix(f[3], "-"))
				}
			}
		case '1':
			if f := strings.SplitN(r, " ", 9); len(f) == 9 {
				st.Files = append(st.Files, File{Path: f[8], Index: f[1][:1], Work: f[1][1:]})
			}
		case '2': // the original path is the next record
			if f := strings.SplitN(r, " ", 10); len(f) == 10 {
				fl := File{Path: f[9], Index: f[1][:1], Work: f[1][1:]}
				if i+1 < len(recs) {
					i++
					fl.Orig = recs[i]
				}
				st.Files = append(st.Files, fl)
			}
		case 'u':
			if f := strings.SplitN(r, " ", 11); len(f) == 11 {
				st.Files = append(st.Files, File{Path: f[10], Index: f[1][:1], Work: f[1][1:], Conflict: true})
			}
		case '?':
			st.Files = append(st.Files, File{Path: r[2:], Index: "?", Work: "?"})
		}
	}
	return st
}

type Commit struct {
	Hash    string   `json:"hash"`
	Parents []string `json:"parents"`
	Author  string   `json:"author"`
	Email   string   `json:"email"`
	Time    int64    `json:"time"` // unix seconds
	Subject string   `json:"subject"`
	Refs    string   `json:"refs,omitempty"`
}

func history(c *plugin.Ctx, raw json.RawMessage) (any, error) {
	var p struct {
		Repo string `json:"repo"`
		N    int    `json:"n"`
		Skip int    `json:"skip"`
		Path string `json:"path"`
	}
	if err := plugin.Decode(raw, &p); err != nil {
		return nil, err
	}
	dir, err := repoOf(c, p.Repo)
	if err != nil {
		return nil, err
	}
	if p.N <= 0 {
		p.N = 50
	}
	p.N = min(p.N, 200)
	args := []string{"log", "-z", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s",
		"-n", strconv.Itoa(p.N), "--skip", strconv.Itoa(max(p.Skip, 0))}
	if p.Path != "" {
		args = append(args, "--", p.Path)
	}
	b, err := run(dir, args...)
	if err != nil {
		if strings.Contains(err.Error(), "does not have any commits") {
			return []Commit{}, nil
		}
		return nil, err
	}
	return parseLog(b), nil
}

func parseLog(b []byte) []Commit {
	out := []Commit{}
	for _, r := range strings.Split(string(b), "\x00") {
		f := strings.SplitN(strings.TrimPrefix(r, "\n"), "\x1f", 7)
		if len(f) != 7 {
			continue
		}
		t, _ := strconv.ParseInt(f[4], 10, 64)
		out = append(out, Commit{Hash: f[0], Parents: strings.Fields(f[1]), Author: f[2], Email: f[3], Time: t, Refs: f[5], Subject: f[6]})
	}
	return out
}

func diff(c *plugin.Ctx, raw json.RawMessage) (any, error) {
	var p struct {
		Repo   string `json:"repo"`
		Path   string `json:"path"`
		Staged bool   `json:"staged"`
		Commit string `json:"commit"`
	}
	if err := plugin.Decode(raw, &p); err != nil {
		return nil, err
	}
	dir, err := repoOf(c, p.Repo)
	if err != nil {
		return nil, err
	}
	var args []string
	switch {
	case p.Commit != "":
		if strings.HasPrefix(p.Commit, "-") {
			return nil, &plugin.Error{Code: "bad", Msg: "bad commit"}
		}
		args = []string{"show", "--no-ext-diff", "--no-textconv", "--no-color", "--format=", "--end-of-options", p.Commit}
	case p.Staged:
		args = []string{"diff", "--no-ext-diff", "--no-textconv", "--no-color", "--cached"}
	default:
		args = []string{"diff", "--no-ext-diff", "--no-textconv", "--no-color"}
	}
	args = append(args, "--")
	if p.Path != "" {
		args = append(args, p.Path)
	}
	b, cut, err := runMax(dir, maxDiff, args...)
	if err != nil {
		return nil, err
	}
	return map[string]any{"diff": string(b), "cut": cut}, nil
}
