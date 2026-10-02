package main

// The laptop's side of shared terminals: `uniai claude` starts Claude in
// a holder (internal/holder) and shows it in this window, so the phones see the same
// terminal; `uniai attach` joins any terminal a phone or another window
// started. Leaving the window (Ctrl-], or closing it) leaves the terminal
// running for everyone else.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/term"

	"uniai/internal/config"
	"uniai/internal/holder"
	"uniai/internal/shellenv"
	"uniai/internal/transcript"
	"uniai/internal/usage"
)

const detachKey = 0x1d // Ctrl-]

func cmdLs(args []string) {
	l := holder.List()
	if len(args) > 0 && args[0] == "--json" { // for the VS Code extension
		if l == nil {
			l = []holder.Info{}
		}
		json.NewEncoder(os.Stdout).Encode(l)
		return
	}
	if len(l) == 0 {
		fmt.Println("no shared terminals")
		return
	}
	sort.Slice(l, func(i, j int) bool { return l[i].Created < l[j].Created })
	home, _ := os.UserHomeDir()
	for _, i := range l {
		dir := i.Dir
		if rel, err := filepath.Rel(home, dir); err == nil && rel == "." {
			dir = "~"
		} else if err == nil && !strings.HasPrefix(rel, "..") {
			dir = "~/" + rel
		}
		fmt.Printf("%-10d %-8s %3dx%-3d %s  %s  (since %s)\n", i.ID, i.Kind, i.Cols, i.Rows, dir, i.Title,
			time.UnixMilli(i.Created).Format("Jan 2 15:04"))
	}
}

// cmdAttach joins a terminal: by id, by folder, or the only one there is.
func cmdAttach(args []string) {
	l := holder.List()
	var pick []holder.Info
	switch {
	case len(args) == 0:
		cwd, _ := os.Getwd()
		for _, i := range l {
			if i.Dir == cwd && i.Kind != "shell" {
				pick = append(pick, i)
			}
		}
		if len(pick) == 0 && len(l) == 1 {
			pick = l
		}
	default:
		want := args[0]
		abs, _ := filepath.Abs(want)
		for _, i := range l {
			if strconv.FormatUint(uint64(i.ID), 10) == want || i.Session == want || i.Dir == abs {
				pick = append(pick, i)
			}
		}
	}
	if len(pick) != 1 {
		if len(l) == 0 {
			die("no shared terminals; start one with `uniai claude`")
		}
		fmt.Fprintln(os.Stderr, "which one? uniai attach <id>")
		cmdLs(nil)
		os.Exit(1)
	}
	os.Exit(attachTerm(pick[0].ID))
}

// cmdKill ends terminal id on every device, like closing its tab on a phone.
func cmdKill(args []string) {
	if len(args) != 1 {
		die("usage: uniai kill <id>  (ids: uniai ls)")
	}
	id, err := strconv.ParseUint(args[0], 10, 32)
	if err != nil {
		die("bad id %q", args[0])
	}
	c, _, err := holder.Dial(uint32(id))
	if err != nil {
		die("terminal %d: %v", id, err)
	}
	defer c.Close()
	holder.WriteFrame(c, 'h')
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	holder.WriteFrame(c, 'a', holder.I64(-1))
	for {
		typ, _, err := holder.ReadFrame(c)
		if err != nil || typ == 'x' {
			return
		}
	}
}

// cmdAgentCLI is `uniai claude|copilot [args]`: the agent in a shared
// terminal, shown here. A conversation already running in one is joined
// rather than started twice (two Claudes on one conversation each miss the
// other's messages).
func cmdAgentCLI(tool string, args []string) {
	if os.Getenv("UNIAI_TERM") != "" {
		execReal(tool, args) // already in a shared terminal (the alias, typed in one)
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		execReal(tool, args)
	}
	cwd, err := os.Getwd()
	if err != nil {
		die("%v", err)
	}
	if tool == "claude" {
		if sid := resumeTarget(cwd, args); sid != "" {
			if pid := transcript.ClaudeRunning()[sid]; pid != 0 {
				if id := holderOf(pid); id != 0 {
					fmt.Fprintf(os.Stderr, "uniai: joining terminal %d, where this conversation is open\n", id)
					os.Exit(attachTerm(id))
				}
				fmt.Fprintf(os.Stderr, "uniai: quitting the Claude that has this conversation open elsewhere (pid %d)…\n", pid)
				if err := transcript.StopClaude(sid); err != nil {
					die("%v", err)
				}
			}
		}
	}
	shell := loginShell()
	if c, err := config.Load(); err == nil {
		shell = pickShell("", c.Shell, shells())
	}
	q := []string{tool}
	for _, a := range args {
		q = append(q, shellenv.Quote(a))
	}
	run := strings.Join(q, " ")
	shell, typed, err := typedCommand(shell, tool, run)
	if err != nil {
		die("%v", err)
	}
	cols, rows, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil || cols <= 0 || rows <= 0 {
		cols, rows = 80, 24
	}
	id, err := holder.Spawn(holder.Spec{Shell: shell, Dir: cwd, Kind: tool, Session: config.RandHex(8), Run: run,
		Typed: typed + "; exit", // quitting it here ends the session everywhere
		Cols:  uint16(cols), Rows: uint16(rows)}, logPath())
	if err != nil {
		die("%v", err)
	}
	os.Exit(attachTerm(id))
}

// execReal runs the real CLI in this process.
func execReal(tool string, args []string) {
	self, _ := os.Executable()
	path, err := exec.LookPath(tool)
	if err != nil {
		die("%s is not on PATH", tool)
	}
	if a, b := realPath(path), realPath(self); a == b {
		die("%s on PATH is uniai itself; point the alias at uniai instead", tool)
	}
	die("%v", syscall.Exec(path, append([]string{tool}, args...), os.Environ()))
}

func realPath(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

// resumeTarget is the conversation args resume: --resume <id>, or
// --continue (the folder's newest).
func resumeTarget(cwd string, args []string) string {
	for i, a := range args {
		switch {
		case (a == "--resume" || a == "-r") && i+1 < len(args) && usage.ReSessionID.MatchString(args[i+1]):
			return args[i+1]
		case strings.HasPrefix(a, "--resume="):
			if v := strings.TrimPrefix(a, "--resume="); usage.ReSessionID.MatchString(v) {
				return v
			}
		case a == "--continue" || a == "-c":
			return newestConversation(cwd)
		}
	}
	return ""
}

func newestConversation(dir string) string {
	files, _ := filepath.Glob(filepath.Join(transcript.ClaudeProjectDir(dir), "*.jsonl"))
	var best string
	var at time.Time
	for _, f := range files {
		if st, err := os.Stat(f); err == nil && st.ModTime().After(at) {
			best, at = f, st.ModTime()
		}
	}
	return strings.TrimSuffix(filepath.Base(best), ".jsonl")
}

// holderOf is the shared terminal process pid runs in (0: none).
func holderOf(pid int) uint32 {
	shells := map[int]uint32{}
	for _, i := range holder.List() {
		shells[i.PID] = i.ID
	}
	pp := transcript.Parents()
	for p, n := pid, 0; p > 1 && n < 20; p, n = pp[p], n+1 {
		if id, ok := shells[p]; ok {
			return id
		}
	}
	return 0
}

// attachTerm shows terminal id in this window until it ends or Ctrl-] leaves
// it; the exit status.
func attachTerm(id uint32) int {
	c, info, err := holder.Dial(id)
	if err != nil {
		die("terminal %d: %v", id, err)
	}
	defer c.Close()
	in, out := int(os.Stdin.Fd()), int(os.Stdout.Fd())
	old, err := term.MakeRaw(in)
	if err != nil {
		die("attach needs a terminal: %v", err)
	}
	restore := func() {
		// Modes the program may have left on: the alternate screen, mouse
		// reports, bracketed paste; and a visible cursor.
		os.Stdout.WriteString("\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[?25h\r\n")
		term.Restore(in, old)
	}
	var mu sync.Mutex
	send := func(typ byte, p []byte) {
		mu.Lock()
		defer mu.Unlock()
		holder.WriteFrame(c, typ, p)
	}
	size := func(role byte) {
		if cols, rows, err := term.GetSize(out); err == nil && cols > 0 && rows > 0 {
			send('r', holder.SizeFrame(uint16(cols), uint16(rows), role))
		}
	}
	os.Stdout.WriteString("\x1b[H\x1b[2J\x1b[3J")
	// A full-screen agent draws itself again for this window's size (the
	// 'L' resize makes sure); old output at another width would only garble.
	// A shell shows its recent lines.
	from := int64(-1)
	if cols, rows, err := term.GetSize(out); info.Kind == "shell" || err != nil || cols <= 0 || rows <= 0 {
		from = max(0, info.End-16<<10) // no size to redraw for: the recent output
	}
	size('L')
	send('a', holder.I64(from))

	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)
	go func() {
		for range winch {
			size('l')
		}
	}()
	detached := make(chan struct{})
	go func() {
		b := make([]byte, 4096)
		for {
			n, err := os.Stdin.Read(b)
			if n > 0 {
				p := b[:n]
				if i := strings.IndexByte(string(p), detachKey); i >= 0 {
					if i > 0 {
						send('i', append([]byte(nil), p[:i]...))
					}
					close(detached)
					c.Close()
					return
				}
				send('i', append([]byte(nil), p...))
			}
			if err != nil {
				return
			}
		}
	}()
	code := 0
	for {
		typ, p, err := holder.ReadFrame(c)
		if err != nil {
			restore()
			select {
			case <-detached:
				fmt.Printf("[left terminal %d; it keeps running — uniai attach %d]\n", id, id)
				return 0
			default:
			}
			if errors.Is(err, os.ErrDeadlineExceeded) {
				err = errors.New("timed out")
			}
			fmt.Printf("[lost terminal %d: %v]\n", id, err)
			return 1
		}
		switch typ {
		case 'o':
			if len(p) > 8 {
				os.Stdout.Write(p[8:])
			}
		case 'x':
			if len(p) >= 4 {
				code = int(int32(uint32(p[0])<<24 | uint32(p[1])<<16 | uint32(p[2])<<8 | uint32(p[3])))
			}
			restore()
			fmt.Println("[session ended]")
			return code
		}
	}
}

const shellSetupMark = "# uniai: claude and copilot in terminals shared with the phones"

// cmdShellSetup aliases claude and copilot to uniai in ~/.zshrc and
// ~/.bashrc (-remove takes it out again).
func cmdShellSetup(args []string) {
	remove := len(args) > 0 && (args[0] == "-remove" || args[0] == "--remove")
	bin := "uniai"
	if _, err := exec.LookPath("uniai"); err != nil {
		// Not on PATH: the LaunchAgent's copy, else this one.
		bin = filepath.Join(config.SupportDir(), "uniai")
		if _, err := os.Stat(bin); err != nil {
			bin = must(os.Executable())
		}
		bin = shellenv.Quote(bin)
	}
	block := fmt.Sprintf("\n%s\nalias claude='%s claude'\nalias copilot='%s copilot'\n", shellSetupMark, bin, bin)
	home, _ := os.UserHomeDir()
	for _, rc := range []string{".zshrc", ".bashrc"} {
		path := filepath.Join(home, rc)
		b, err := os.ReadFile(path)
		if err != nil && (rc != ".zshrc" || remove) {
			continue // no bash setup to add to
		}
		s := string(b)
		if i := strings.Index(s, "\n"+shellSetupMark+"\n"); i >= 0 {
			end := i + 1 + len(shellSetupMark) + 1
			for _, l := range []string{"alias claude=", "alias copilot="} {
				if strings.HasPrefix(s[end:], l) {
					if j := strings.IndexByte(s[end:], '\n'); j >= 0 {
						end += j + 1
					} else {
						end = len(s)
					}
				}
			}
			s = s[:i] + s[end:]
		}
		if !remove {
			s += block
		}
		if s == string(b) {
			continue
		}
		if err := os.WriteFile(path, []byte(s), 0o644); err != nil {
			die("%v", err)
		}
		if remove {
			fmt.Println("removed the aliases from", path)
		} else {
			fmt.Println("added to", path+": claude and copilot now open in shared terminals (new windows)")
		}
	}
}

func must[T any](v T, err error) T {
	if err != nil {
		die("%v", err)
	}
	return v
}
