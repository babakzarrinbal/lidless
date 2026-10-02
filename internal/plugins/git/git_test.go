package git

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"macremote/internal/plugin"
)

func sh(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=T", "-c", "user.email=t@x", "-c", "init.defaultBranch=main"}, args...)...)
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, b)
	}
}

func write(t *testing.T, path, text string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// ctx allows everything under root, like the core's shared folders.
func ctx(root string) *plugin.Ctx {
	return &plugin.Ctx{Device: "test", Log: func(string, ...any) {}, Resolve: func(p string) (string, error) {
		r, err := filepath.EvalSymlinks(p)
		if err != nil {
			return "", err
		}
		if r != root && !strings.HasPrefix(r, root+"/") {
			return "", &plugin.Error{Code: "denied", Msg: "outside"}
		}
		return r, nil
	}}
}

func call[T any](t *testing.T, c *plugin.Ctx, m string, p any) T {
	t.Helper()
	reg := plugin.New(Plugin())
	raw, _ := json.Marshal(p)
	res, err := reg.Lookup(m).Call(c, raw)
	if err != nil {
		t.Fatalf("%s: %v", m, err)
	}
	b, _ := json.Marshal(res)
	var v T
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	root, _ := filepath.EvalSymlinks(t.TempDir())
	a := filepath.Join(root, "a")
	b := filepath.Join(root, "group", "b")
	write(t, filepath.Join(root, "node_modules", "x", ".git", "HEAD"), "") // skipped
	for _, d := range []string{a, b} {
		os.MkdirAll(d, 0o755)
		sh(t, d, "init", "-q")
	}
	write(t, filepath.Join(a, "one.txt"), "one\n")
	write(t, filepath.Join(a, "two words.txt"), "two\n")
	sh(t, a, "add", ".")
	sh(t, a, "commit", "-qm", "first")
	write(t, filepath.Join(a, "one.txt"), "one\nmore\n")
	sh(t, a, "mv", "two words.txt", "three.txt")
	write(t, filepath.Join(a, "new.txt"), "new\n")
	c := ctx(root)

	repos := call[[]Repo](t, c, "git.repos", map[string]any{"dir": root})
	if len(repos) != 2 || repos[0].Rel != "a" || repos[1].Rel != "group/b" {
		t.Fatalf("repos: %+v", repos)
	}
	if repos[0].Branch != "main" || repos[0].Changed != 3 {
		t.Fatalf("repo a: %+v", repos[0])
	}

	st := call[Status](t, c, "git.status", map[string]any{"repo": a})
	got := map[string]File{}
	for _, f := range st.Files {
		got[f.Path] = f
	}
	if f := got["one.txt"]; f.Index != "." || f.Work != "M" {
		t.Errorf("one.txt: %+v", f)
	}
	if f := got["three.txt"]; f.Index != "R" || f.Orig != "two words.txt" {
		t.Errorf("rename: %+v", f)
	}
	if f := got["new.txt"]; f.Index != "?" {
		t.Errorf("untracked: %+v", f)
	}
	if st.Branch != "main" || st.Commit == "" {
		t.Errorf("status: %+v", st)
	}

	lg := call[[]Commit](t, c, "git.log", map[string]any{"repo": a})
	if len(lg) != 1 || lg[0].Subject != "first" || lg[0].Author != "T" || len(lg[0].Parents) != 0 {
		t.Errorf("log: %+v", lg)
	}
	if e := call[[]Commit](t, c, "git.log", map[string]any{"repo": b}); len(e) != 0 {
		t.Errorf("empty repo log: %+v", e)
	}

	d := call[map[string]any](t, c, "git.diff", map[string]any{"repo": a, "path": "one.txt"})
	if !strings.Contains(d["diff"].(string), "+more") {
		t.Errorf("diff: %v", d)
	}
	d = call[map[string]any](t, c, "git.diff", map[string]any{"repo": a, "commit": lg[0].Hash})
	if !strings.Contains(d["diff"].(string), "+two") {
		t.Errorf("show: %v", d)
	}

	reg := plugin.New(Plugin())
	if _, err := reg.Lookup("git.diff").Call(c, json.RawMessage(`{"repo":"`+a+`","commit":"one.txt"}`)); err == nil {
		t.Error("a file name taken as a commit")
	}
	// A repository's config must not run commands through the plugin.
	pwned := filepath.Join(root, "pwned")
	sh(t, b, "config", "core.fsmonitor", "touch "+pwned)
	call[Status](t, c, "git.status", map[string]any{"repo": b})
	if _, err := os.Stat(pwned); err == nil {
		t.Error("core.fsmonitor ran")
	}
	if _, err := reg.Lookup("git.status").Call(c, json.RawMessage(`{"repo":"`+filepath.Join(a, "..")+`"}`)); err == nil {
		t.Error("status of a folder that is not a repository")
	}
	if _, err := reg.Lookup("git.status").Call(c, json.RawMessage(`{"repo":"/"}`)); err == nil {
		t.Error("status outside the shared folders")
	}
}
