# internal/holder

The process that owns one shared terminal (its pty and shell), and the client
side of the unix-socket protocol it speaks. A holder runs in its own session,
so terminals outlive the agent: an agent restart or upgrade keeps them.

Entry points: `Run(args)` is the holder process (`uniai hold …`); `Spawn(spec,
logPath)` starts one; `Dial(id)` connects and returns its `Info`; `IDs()` and
`List()` find the holders on this Mac; `Ring` is the append-only output buffer
addressed by byte offset; `WriteFrame`/`ReadFrame` speak the frames
`[type][len u32][payload]`.

Test: `./dev.sh go test ./internal/holder`

Traps:
- Holders outlive upgrades. The frame format, the `hold` CLI arguments, the
  socket path (`TermsDir()/<id>.sock`) and the file names must stay
  byte-identical; an older holder must still be adopted. `holdProto` only
  grows. See docs/architecture.md, "Holder protocol".
- The log path is passed to `Spawn` by the caller; this package does not know
  the agent's log file.
- A laptop window attached to a terminal wins the size over the phones.
