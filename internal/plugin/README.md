# internal/plugin

The core's plugin registry. A plugin registers methods in its own namespace
("git.status"); each method describes itself (one line, a JSON schema for its
parameters, whether it changes anything), so the same registry serves the apps
(`plugins.list`) and, later, AI sessions as MCP tools.

Entry points: `Registry`, `Method`, `Ctx`; the core builds its registry in
`cmd/uniai/plugins.go`, and `rpc.go` hands it any method the built-in switch
does not know. Plugins live in `internal/plugins/<name>` (git first).

Test: `./dev.sh test internal/plugin`, `./dev.sh test internal/plugins/git`

Traps:
- `Error` is `rpc.Error`: return it with a code the app can act on
  ("denied", "norepo", …), never a bare error string.
- A method that changes anything sets `Write`: an AI must ask before calling it.
- Plan and phases: docs/native-app.md, "Plugins".
