# How bz-uniai works

The whole system in one page: what runs where, how a terminal is shared by
every device, and the traps. Product overview: [README.md](../README.md).
Working rules and commands: [AGENTS.md](../AGENTS.md).

## The pieces

```
 phone app ──WSS──▶ relay ◀──WSS── agent (uniai serve, LaunchAgent)
   └──────── Noise_IK, end to end ───────┘     │ unix sockets
                                               ▼
 laptop window ── uniai attach ──▶ holders (uniai hold, one per terminal)
                                               │ pty
                                               ▼
                                     login shell → claude / copilot / …
```

| Process | Code | Lives | Job |
|---|---|---|---|
| relay | `cmd/relay` | Docker on the server | Pairs a phone socket with its Mac's socket (same room). Sees only ciphertext. |
| agent | `cmd/uniai` `serve` | LaunchAgent or brew service, one per Mac (`lock.go`) | Dials the relay, authenticates phones (Noise static keys), serves RPCs: terminals, files, chat transcripts, status. |
| holder | `cmd/uniai` `hold` (`hold.go`) | One per terminal, own session (setsid), outlives the agent | Owns the pty and the shell, keeps the last 1–2 MiB of output, serves any number of clients on a unix socket. |
| laptop CLI | `attach.go` | A Terminal window on the Mac | `uniai claude`, `attach`, `ls`, `kill`. A holder client like the agent. |
| app | `app/` (Flutter) | The phones | Tabs per terminal, grouped into sessions; chat view from transcripts; files; editor. |

## One terminal, every device

The holder is the terminal. Everything else is a window onto it:

- **The agent** connects to every holder (it finds them in
  `~/.config/uniai/terms/<id>.sock`, scanning every second) and mirrors
  each one's output into its own ring. Phones talk to the agent only.
- **A phone** lists terminals (`term.list`), attaches from the byte offset it
  has seen (`term.attach`), and gets output as `'O'` frames carrying the offset,
  so a reconnect resumes without gaps or repeats.
- **A laptop window** (`uniai attach <id>` or `uniai claude`) connects
  to the holder directly.

Consequences:

- Opening a session anywhere makes it visible everywhere. There is nothing to
  "move": the agent sends `{"ev":"terms"}` to every phone when a terminal comes
  or goes, and phones adopt new ones live (`Terms._refresh` in
  `app/lib/features/terminals/terms.dart`). A laptop sees them with `uniai ls`.
- Input from any client goes to the same pty. Everyone sees the same screen.
- Restarting or upgrading the agent (`agent-install`, `brew upgrade`) does not
  end terminals. The new agent re-adopts the holders. The plist sets
  `AbandonProcessGroup` and holders run in their own session, so launchd does
  not take them down with the agent.
- A terminal ends only when its shell exits: `exit`, quitting the `claude` it
  was started for (`uniai claude` types `claude …; exit`), closing it on a
  phone (`term.close`), `uniai kill <id>`, or a SIGTERM to the holder. Its
  clients then get `'x'` with the exit code, and the socket is removed.

### Size policy

There is one pty, so it has one size. While a laptop window is attached, the
laptop that resized most recently wins: you are at the keyboard. Otherwise the
phones' last size applies. When the last laptop leaves, the size goes back to
the phones'. A window that attaches at the size the pty already has gets a
redraw nudge (rows−1, then back): a full-screen program like Claude redraws on
SIGWINCH. So `attach` shows the current screen, not stale bytes at another
width. A plain shell gets its last 16 KiB replayed instead.

### Holder protocol (`hold.go`)

Frames are `[type u8][len u32 BE][payload]`, max 1 MiB.

| Dir | Type | Payload |
|---|---|---|
| holder → client | `n` | info JSON, always first: `v` (protocol), `id`, `kind`, `session`, `dir`, `title`, `run`, `created` (ms), `pid` (the shell), `cols`, `rows`, `end`, `exited`, `code` |
| | `o` | offset i64 + output bytes |
| | `s` | cols u16, rows u16: the pty was resized |
| | `x` | exit code i32: the shell ended |
| client → holder | `a` | from i64: stream output from this offset (−1: from the end) |
| | `i` | input bytes |
| | `r` | cols u16, rows u16, role: `p` phones (via the agent), `l` laptop, `L` laptop that just attached |
| | `h` | hang up: SIGHUP to the shell's group, SIGKILL after 3 s |
| | `t` | new title |

**Old holders outlive upgrades.** A holder started by last week's binary
still runs after `brew upgrade`. So only add frame types or info fields, and
never change what an existing one means. Bump `holdProto` only together with
code that still speaks every older version (`dialHold` refuses only newer
ones).

### Ids and sessions

A terminal id is a random u32 (1..2³¹−1) that no socket uses yet. It is also
the phone's tab id. A **session** is a string tag (`session`) shared by one
agent terminal (`kind` `claude`/`copilot`, or `cli`) and any number of shells
(`kind` `shell`). The phone groups tabs into sessions by that tag. A terminal
without one is not shown on phones (`uniai claude` always sets one).

## Claude and Copilot

- `uniai claude [args]` (and `copilot`) runs the agent CLI in a new holder
  and attaches this window. `uniai shell-setup` aliases `claude` and
  `copilot` to it in `~/.zshrc`, so typing `claude` on the Mac is shared by
  default. Inside a holder (`UNIAI_TERM` is set), or without a TTY, the
  alias runs the real CLI.
- Resuming a conversation that already runs in a holder (`--resume <id>`,
  `-c`) joins that terminal instead of starting a second Claude. Two Claudes on
  one conversation each miss the other's messages. If it runs outside a holder
  (an editor, a terminal without the alias), the CLI quits that Claude first
  (`stopClaude`, it saves) and resumes in a holder.
- The phone does the same when you pick a conversation. If it runs in a shared
  terminal, the phone shows that session. If it runs outside one, the phone
  offers a single **Move here** (`chat.stop` quits that Claude or Copilot
  CLI, which saves; then it resumes in a new shared terminal). A VS Code
  Copilot Chat moves the same way: `chat.handoff` writes it out as markdown
  and a Copilot CLI in a new shared terminal carries it on (`vscode.go`),
  told to read only the end of it. The chat view shows the VS Code chat's
  history first (a snapshot of its items), then "Disconnected from the
  original chat", then the session (`moved.go`).
- The chat view reads transcripts, not the screen:
  `~/.claude/projects/<folder>/<conversation>.jsonl` and
  `~/.copilot/session-state/<id>/events.jsonl` (`chat.go`, `claude.go`,
  `copilot.go`). The terminal→conversation link is the process tree: which
  Claude pid runs under the terminal's shell pid.

### Parking (history)

Before holders, a Claude could only be in one place, so the phone quit an
idle Claude when you left its session ("parked" it) and restarted it when you
came back. That is gone. Shared terminals made it pointless, and it lost
in-flight text. `term.park`/`term.unpark` remain for terminals an older app
parked. Parked state lives only in the agent's memory.

## The phone side

- `lib/net/link.dart`: one connection per Mac, reconnects, RPC calls with
  timeouts, `termOut` callbacks per terminal id, the `events` stream.
- `lib/features/terminals/terms.dart`: `_sync` after every (re)connect adopts the Mac's
  list and resumes each tab from its offset. `_refresh` on `terms` events
  adopts only new terminals, takes renames, and marks gone ones ended. A
  `term.closed` event (any device called `term.close`) drops the tab on
  every device at once. `open()` keeps one tab
  when the event beats the reply. The status dots (working / unread / read /
  closed) come from output activity and the screen (`LiveScreen`), and the
  read offsets are saved per Mac.
- The app must handle an older agent: an `RpcError` with code `unknown`. Macs
  update separately through brew.

### Pairing

A pairing code (`mr1.<base64url json>`: relay, pin, room, Mac key, one-time
token, host) comes from `devices.pair` or `uniai pair`; the token lasts 10
minutes and a new code replaces the last one. The device sends the token in
its Noise hello (`pair`), and the core adds the device's key to agent.json.

Two desktops pair both ways. A Mac's app sends its own core's code along
(`back` in the hello, `Link.back`). The other core keeps it in
`~/.config/uniai/offers.json` (`offers.go`) and says `{"ev":"devices"}`; its
app takes the codes with `devices.offers` (local session only) and pairs with
each Mac it does not know yet (`features/devices/pair_back.dart`). If that app
is not running within the 10 minutes, the code expires and the user pairs
that way by hand. Phones run no core, so they pair one way.

### Unread and notifications

A tab is unread when an agent terminal has more than 512 bytes past its read
offset. The traps, and what handles each one:

- **Read on one phone, read on all.** A phone that shows output sends
  `term.seen {id, seen}` (debounced 1 s). The agent keeps the highest offset
  per terminal, lists it as `seen` in `term.list`, and broadcasts a
  `term.seen` event. The other phones raise their read offset and drop the
  notification (`Terms._seenElsewhere`).
- **A resize is not news.** Any resize makes Claude redraw the whole screen.
  The agent broadcasts `term.size` when a holder reports a new size. For
  1.5 s after that (or after its own resize), a phone treats the output as the
  same screen again, unless the tab is already working.
- **Hidden tabs don't resize.** A tab that was never on screen has the
  emulator's 80x24. It attaches with `cols`/`rows` 0, which the agent ignores,
  so a reconnecting phone does not shrink the terminal for everyone.
- **Only an answer notifies.** Claude shows a status line ("esc to
  interrupt", the spinner) while it works. A burst of output in a `claude`
  tab with no status line on screen (laptop typing, a focus redraw) settles
  without a notification, and stays read if it was read before. Output that
  arrived while the phone was away comes in one burst, too fast to sample, so
  it counts as work.
- **Leaving right after asking.** Android lets the keep-alive service
  (`WatchService`, "An agent is working") start only while the app shows, in
  `MainActivity.onPause`. Without it the app loses its network seconds later
  and never hears the answer. So a Claude/Copilot tab typed into within the
  last 30 s counts as busy (`Terms.expecting`), even before its output starts.
  The redraw window also gives way as soon as the status line shows.
- Not handled yet: reading on the laptop does not mark the phones read.

## Working on it

- **Go:** only in Docker: `./dev.sh go-check`, `./dev.sh go test -run X
  ./cmd/uniai`, `./dev.sh agent` (builds `bin/uniai`).
  `hold_test.go` drives a holder over pipes.
- **Try holders without touching the live agent:** everything keys off `$HOME`
  (config, sockets, log). Use a scratch `HOME` with a short path: unix socket
  paths max out at 104 bytes on macOS. Run `uniai init -relay
  127.0.0.1:9 -pin <64 zeros>`, then `uniai serve` (logs to stderr) and
  `uniai hold -id 77 -dir … -run 'echo hi'`.
- **App:** `./dev.sh app-analyze`, `./dev.sh app-test`. `test/sync_test.dart`
  covers the shared-terminal sync, and `FakeLink.macEvents` injects agent
  events.
- **Deploying the agent:** `./dev.sh agent-install` restarts the agent but
  keeps holder terminals. The one exception is the first switch from a
  pre-holder agent: its terminals lived inside the old agent and end with it,
  including a Claude driving this repo from a phone. `install` restarts the
  agent from a detached `uniai reload` (own session, logs to the agent
  log), so running it from a phone's terminal cannot leave the Mac without an
  agent.
