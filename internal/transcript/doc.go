// Package transcript reads and writes the AI tools' chat transcripts on this
// Mac: Claude Code's (claude.go, chat.go), GitHub Copilot CLI's (copilot.go)
// and VS Code Copilot Chat's (vscode.go), and carries a VS Code chat on in a
// shared terminal and back (vscodemirror.go, with the embedded bz-uniai VS Code
// extension in vscode-ext/). The phone's chat view (`chat.*` RPCs) is built
// on it. Overview: docs/architecture.md.
package transcript

// Terminal is what the readers need to know about one of the agent's shared
// terminals. The agent (cmd/uniai/term.go) builds these from its own terminal
// type, so this package does not depend on the agent.
type Terminal struct {
	ID      uint32
	Kind    string // "claude", "copilot" or "shell"
	Session string
	Dir     string
	Pid     int           // the terminal's shell process
	Run     string        // the command the terminal started with
	Title   func() string // the terminal's title, read on demand
}
