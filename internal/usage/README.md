# internal/usage

Usage numbers for the phone: context window and plan limits (Claude via its
status line, Copilot via its quota), and a token ledger.

Files: `usage.go` (status line snapshots, `uniai usage`), `limits.go` (plan
limits from the providers), `tokens.go` (the ledger, counted once per chat).

Entry points: `CmdStatusline`, `CmdUsage`, `StatuslineEnsure` (the CLI
subcommands and the `settings.json` hook), `ReadStatus(sid)`, `ClaudeUsage()`
(the `usage` RPC), `TokenLedger` (`TokenTotals`, `Reset`, `ChatTokens`),
`KeepCounting()` (the agent's background counter), `ReSessionID` (what a
conversation id looks like; shared with the transcript readers).

Test: `./dev.sh go test ./internal/usage`

Traps: Claude's status line hands over a JSON snapshot per answer, so a chat
that never answered has none. Tokens must be counted once, however many times
a transcript is re-read. Limits calls use the user's own login, never log
them. Files live in `config.SupportDir()`.
