package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"uniai/internal/plugin"
)

const maxEditable = 4 << 20

// rpcError carries a machine-readable code to the phone. Plugins return the
// same type.
type rpcError = plugin.Error

// resolve turns a phone-supplied path into a real absolute path inside one of
// the configured roots, following symlinks so a link cannot point outside.
func resolve(roots []string, p string) (string, error) {
	home, _ := os.UserHomeDir()
	if p == "~" || strings.HasPrefix(p, "~/") {
		p = home + p[1:]
	}
	if !filepath.IsAbs(p) {
		return "", errors.New("path must be absolute")
	}
	p = filepath.Clean(p)
	real, err := filepath.EvalSymlinks(p)
	if err != nil {
		// A file about to be created: resolve its folder instead.
		dir, err2 := filepath.EvalSymlinks(filepath.Dir(p))
		if err2 != nil {
			return "", err
		}
		real = filepath.Join(dir, filepath.Base(p))
	}
	for _, r := range roots {
		rr, err := filepath.EvalSymlinks(r)
		if err != nil {
			continue
		}
		if real == rr || strings.HasPrefix(real, rr+string(filepath.Separator)) {
			return real, nil
		}
	}
	return "", &rpcError{Code: "denied", Msg: "outside the allowed folders"}
}

type Entry struct {
	Name  string `json:"name"`
	Dir   bool   `json:"dir"`
	Link  bool   `json:"link,omitempty"`
	Size  int64  `json:"size"`
	Mtime int64  `json:"mtime"` // unix ms
}

func fsList(roots []string, path string) (map[string]any, error) {
	p, err := resolve(roots, path)
	if err != nil {
		return nil, err
	}
	des, err := os.ReadDir(p)
	if err != nil {
		return nil, err
	}
	out := make([]Entry, 0, len(des))
	for _, d := range des {
		info, err := d.Info()
		if err != nil {
			continue
		}
		e := Entry{Name: d.Name(), Dir: d.IsDir(), Size: info.Size(), Mtime: info.ModTime().UnixMilli()}
		if info.Mode()&os.ModeSymlink != 0 {
			e.Link = true
			if st, err := os.Stat(filepath.Join(p, d.Name())); err == nil {
				e.Dir, e.Size = st.IsDir(), st.Size()
			}
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Dir != out[j].Dir {
			return out[i].Dir
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	truncated := false
	if len(out) > 5000 {
		out, truncated = out[:5000], true
	}
	return map[string]any{"path": p, "entries": out, "truncated": truncated}, nil
}

func fsRead(roots []string, path string) (map[string]any, error) {
	p, err := resolve(roots, path)
	if err != nil {
		return nil, err
	}
	st, err := os.Stat(p)
	if err != nil {
		return nil, err
	}
	if st.IsDir() {
		return nil, &rpcError{Code: "isdir", Msg: "that is a folder"}
	}
	res := map[string]any{"path": p, "size": st.Size(), "mtime": st.ModTime().UnixNano()}
	if st.Size() > maxEditable {
		res["tooLarge"] = true
		return res, nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, err
	}
	head := b
	if len(head) > 8000 {
		head = head[:8000]
	}
	if bytes.IndexByte(head, 0) >= 0 || !utf8.Valid(b) {
		res["binary"] = true
		return res, nil
	}
	res["text"] = string(b)
	return res, nil
}

// fsWrite saves text atomically. A non-zero mtime must match the file on
// disk, so an edit never silently overwrites a change made on the Mac.
func fsWrite(roots []string, path, text string, mtime int64) (map[string]any, error) {
	p, err := resolve(roots, path)
	if err != nil {
		return nil, err
	}
	mode := os.FileMode(0o644)
	if st, err := os.Stat(p); err == nil {
		if st.IsDir() {
			return nil, &rpcError{Code: "isdir", Msg: "that is a folder"}
		}
		if mtime != 0 && st.ModTime().UnixNano() != mtime {
			return nil, &rpcError{Code: "conflict", Msg: "the file changed on the Mac since you opened it"}
		}
		mode = st.Mode().Perm()
	} else if mtime != 0 {
		return nil, &rpcError{Code: "conflict", Msg: "the file was deleted on the Mac"}
	}
	f, err := os.CreateTemp(filepath.Dir(p), "."+filepath.Base(p)+".uniai-*")
	if err != nil {
		return nil, err
	}
	tmp := f.Name()
	_, err = f.WriteString(text)
	if err == nil {
		err = f.Chmod(mode)
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, p)
	}
	if err != nil {
		os.Remove(tmp)
		return nil, err
	}
	st, err := os.Stat(p)
	if err != nil {
		return nil, err
	}
	return map[string]any{"path": p, "size": st.Size(), "mtime": st.ModTime().UnixNano()}, nil
}

func fsMkdir(roots []string, path string) error {
	p, err := resolve(roots, path)
	if err != nil {
		return err
	}
	return os.Mkdir(p, 0o755)
}

func fsCreate(roots []string, path string) error {
	p, err := resolve(roots, path)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	return f.Close()
}

func fsRename(roots []string, from, to string) error {
	a, err := resolveEntry(roots, from)
	if err != nil {
		return err
	}
	b, err := resolveEntry(roots, to)
	if err != nil {
		return err
	}
	if _, err := os.Lstat(b); err == nil {
		return &rpcError{Code: "exists", Msg: "something with that name already exists"}
	}
	return os.Rename(a, b)
}

// fsDelete removes a file or an empty folder, never a whole tree.
func fsDelete(roots []string, path string) error {
	p, err := resolveEntry(roots, path)
	if err != nil {
		return err
	}
	return os.Remove(p)
}

// resolveEntry resolves a path's folder but not its last element, so a
// rename or delete acts on a symlink itself rather than its target. A root
// itself is never an entry.
func resolveEntry(roots []string, path string) (string, error) {
	home, _ := os.UserHomeDir()
	if strings.HasPrefix(path, "~/") {
		path = home + path[1:]
	}
	clean := filepath.Clean(path)
	base := filepath.Base(clean)
	if !filepath.IsAbs(clean) || base == "/" || base == "." || base == ".." {
		return "", errors.New("bad path")
	}
	dir, err := resolve(roots, filepath.Dir(clean))
	if err != nil {
		return "", err
	}
	p := filepath.Join(dir, base)
	for _, r := range roots {
		if rr, err := filepath.EvalSymlinks(r); err == nil && rr == p {
			return "", &rpcError{Code: "denied", Msg: "that is a root folder"}
		}
	}
	return p, nil
}
