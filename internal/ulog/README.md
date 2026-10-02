# internal/ulog

The agent's logger. One timestamped line per call on stdout; the service
manager writes it to the agent log (`./dev.sh log`).

Entry points: `Logf(format, args…)`; `For("term")` returns a logger whose
lines start with `term: `. Give each package its own prefix.

Test: `./dev.sh go test ./internal/ulog`

Traps: stdout only, no levels. Never log keys, tokens or the relay address
(the repo is public, and logs get pasted into issues).
