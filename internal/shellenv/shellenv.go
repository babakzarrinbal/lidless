// Package shellenv builds the environment for every child the core starts for
// a person's terminal (a holder's shell, `claude`, `copilot`, the usage probes)
// so they all see the same TERM and none leaks the agent's own. Terminals:
// docs/architecture.md.
package shellenv

import (
	"os"
	"strings"
)

// Env is os.Environ() without the terminal variables of whatever started the
// agent (TERM, TERM_PROGRAM, XPC_*, UNIAI_TERM), plus a truecolor xterm TERM
// and a UTF-8 LANG when none is set.
func Env() []string {
	env := []string{}
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "XPC_SERVICE_NAME", "XPC_FLAGS", "UNIAI_TERM":
			continue
		}
		env = append(env, kv)
	}
	env = append(env, "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=Uniai")
	if os.Getenv("LANG") == "" {
		env = append(env, "LANG=en_US.UTF-8")
	}
	return env
}

// Quote makes s one word for a shell command line: unchanged when it has
// nothing special in it, otherwise in single quotes.
func Quote(s string) string {
	if !strings.ContainsAny(s, " '\"\\$`!*?&;|<>()[]{}#~") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
