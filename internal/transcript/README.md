# internal/transcript

Reads (and for VS Code, writes) the AI tools' chat transcripts on this Mac,
for the phone's chat view and Recent list.

Files: `chat.go` (chat items, `chat.read`/`older`), `claude.go` (Claude Code
transcripts, running processes, conversation lists), `copilot.go` (Copilot
CLI), `vscode.go` (VS Code Copilot Chat files), `vscodemirror.go` (a chat
carried on in a shared terminal is mirrored back; installs the embedded
extension in `vscode-ext/`), `doc.go` (`Terminal`).

Entry points: `ChatRead`, `ChatOlder`, `ChatSessions`, `ChatRecent`,
`ChatCommands`, `VSCodeConversations`, `VSCodeTranscript`, `VSCodeHandoff`,
`MirrorVSCode(list)`, `VSCodeExtInstall`, `CopilotCommand`, `StopClaude`,
`QuitClaude`, `ClaudeRunning`, `ClaudeProjectDir`.

The agent passes its terminals as `*Terminal` (built in `cmd/uniai/term.go`,
`forChat`), so this package knows nothing of the agent.

Test: `./dev.sh go test ./internal/transcript`

Traps: VS Code keeps an open chat in memory and edits its file by index: the
mirror writes nothing while the chat is open (see the header of
`vscodemirror.go`). Transcripts are read from a byte offset, never whole.
`ps` is how a terminal finds its Claude: keep `Parents` cheap. Never run a
copilot shim from VS Code (`copilotBin` skips it).
