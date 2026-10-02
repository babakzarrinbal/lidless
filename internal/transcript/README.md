# internal/transcript

Reads the AI tools' chat transcripts on this Mac, for the app's chat view and
Recent list, and moves an outside conversation into a shared terminal.

Files: `chat.go` (chat items, `chat.read`/`older`), `claude.go` (Claude Code
transcripts, running processes, conversation lists), `copilot.go` (Copilot
CLI), `copilot_session.go` (which session a running Copilot has open), `vscode.go` (VS Code Copilot Chat: listing, handoff to Copilot),
`vscode_scan.go` (a chat's label without parsing it), `vscode_items.go`
(reading one VS Code chat file), `doc.go` (`Terminal`).

Entry points: `ChatRead`, `ChatOlder`, `ChatSessions`, `ChatRecent`,
`ChatCommands`, `WithVSCode`, `VSCodeConversations`, `VSCodeHandoff`,
`CopilotCommand`, `StopClaude`, `StopCopilot`, `QuitAgent`, `ClaudeRunning`,
`ClaudeProjectDir`.

"Move here" (the app's `SessionFlows.resumeIn`): `chat.stop` quits the
outside Claude or Copilot, then the app resumes it in a shared terminal. A VS
Code chat can't be resumed by a CLI: `chat.handoff` writes it out as
`<id>.md` and Copilot starts with a prompt naming it. The terminal and the
Copilot session that follow are tied to the chat by that path (`reHandoff`).

The agent passes its terminals as `*Terminal` (built in `cmd/uniai/term.go`,
`forChat`), so this package knows nothing of the agent.

Test: `./dev.sh test internal/transcript`

Traps: transcripts are read from a byte offset, never whole. `ps` is how a
terminal finds its Claude: keep `Parents` cheap. Never run a copilot shim
from VS Code (`copilotBin` skips it), and never quit VS Code's Copilot
runtime (`copilotCLI` tells it apart): it serves every chat in VS Code.
VS Code's chats live in `workspaceStorage/<hash>/chatSessions/`, spelled
exactly so: macOS hides a wrong case, Linux CI does not. Listing them only
ever scans each file (`vscodeScan`) — replaying one (`vscodeState`) costs its
whole size, and chats here run past 100 MB.
A resumed Copilot (1.0.9x) holds no `inuse.<pid>.lock`: its process log
(`~/.copilot/logs/process-<ms>-<pid>.log`, "Registering foreground session")
is what ties it to its session, and `events.jsonl` appears only with the
first message.
