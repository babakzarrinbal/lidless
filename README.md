# bz-uniai

A personal Android app that gives the phone a terminal and the files of a Mac,
next to the Claude Code app.

```
phone ──WSS──▶ relay (your.server:8460) ◀──WSS── uniai agent (Mac)
        └──────────── Noise_IK end-to-end ─────────────┘
```

- **Relay** (`cmd/relay`, Docker on the server): a dumb pipe that pairs one
  phone socket with the Mac socket of the same room. TLS 1.3 with a self-signed
  certificate; both ends pin sha256(cert DER). It never sees plaintext.
- **Agent** (`cmd/uniai`, LaunchAgent): dials out to the relay, so the Mac
  needs no open port and no setup. Phones are authorized by their Noise static
  key; `uniai pair` issues a one-time token (10 min) as a QR/text code.
  Each terminal runs in its own holder process, so it outlives the phone's
  connection and the agent itself, and every device sees the same one. The first
  agent to connect claims its room with its room key; the relay refuses any
  other agent for that room.
- **App** (`app/`, Flutter): Noise_IK_25519_ChaChaPoly_SHA256 (prologue
  `uniai/1`, tested against flynn/noise vectors), xterm terminal tabs,
  file browser and code editor (re_editor), biometric lock.

## Install

On a Mac, install the app: `./dev.sh mac-zip` builds `build/bz-uniai-mac.zip`.
The app carries the core and, at every start, installs it as a LaunchAgent
(unless a newer one runs), along with the `uniai` command and the
claude/copilot shell aliases. Built with `.server.env`, it also carries your
relay, so phones pair from its Devices page. To install or update it on another
Mac, unzip it outside /Applications first (`ditto -x -k` straight into
/Applications fails: it can't change that folder's own permissions):

```bash
pkill -x bz-uniai
ditto -x -k ~/Downloads/bz-uniai-mac.zip ~/Downloads/bz-uniai-new
rm -rf /Applications/bz-uniai.app
mv ~/Downloads/bz-uniai-new/bz-uniai.app /Applications/
xattr -dr com.apple.quarantine /Applications/bz-uniai.app
open /Applications/bz-uniai.app
```

Without the app:
`brew install babakzarrinbal/uniai/uniai`, then `uniai setup your.server:8460`. To run a relay, see
[docs/hosting.md](docs/hosting.md).

## Sessions

The app's main screen is one session: a folder on the Mac running Claude Code,
Copilot or a plain terminal (chosen with its flags on the New session page).
That agent fills the top; below it are a collapsible shell pane (any number of
shell tabs in the same folder) and a collapsible files pane that opens at the
session folder (hidden files shown; it can go above it). Drag a pane's header
to resize it. The keyboard comes up only from the ⌨ key or the agent's input
bar, and while it is up only the focused pane shows. The drawer lists the
sessions on the Mac and the paired Macs: each Mac has its own phone key, one is
connected at a time, and terminals keep running on a Mac while another is open.
All of a session's terminals carry its id on the Mac (`term.open` `session`,
`kind`), so the list survives the app being closed.

Shells: a Mac's default shell for new terminals is set in the drawer's
**Manage Macs** page (from the Mac's `/etc/shells`, else its login shell). One
terminal can use another: long-press **+** in the shell tabs, or tap the shell
button next to **Start** on the New session page. Manage Macs also renames
(a nickname on the phone) and removes paired Macs.

**One terminal, every device.** A session opened on a phone shows up on the
other phones within a second, and on the Mac with `uniai ls` and
`uniai attach <id>` (Ctrl-] leaves it running). A Claude started on the
Mac with `uniai claude`, or plain `claude` after `uniai shell-setup`,
shows up on the phones. There is no moving a session: every device is a window
onto the same terminal. While a laptop window is attached, its size wins.
`uniai kill <id>` ends one everywhere. How it works:
[docs/architecture.md](docs/architecture.md).

Copilot is started as `copilot` from a login shell: `~/.local/bin/copilot`
links to VS Code's Copilot CLI shim.

Wire format, framing and RPC methods: the header of `cmd/uniai/wire.go`
and `app/lib/net/link.dart`.

## Commands

Working on it: [AGENTS.md](AGENTS.md) (notes for coding agents and humans) and
[docs/dev-setup.md](docs/dev-setup.md) (a new Mac; `./dev.sh doctor` checks it).
`./dev.sh` lists everything. Common ones:

- `./dev.sh agent-install` — build the agent, init it against the relay, install
  the LaunchAgent and link `~/.local/bin/uniai` (the Mac app does the same).
- `uniai pair | devices | revoke <n> | status` — on the Mac.
- `uniai ls | attach [id] | kill <id> | claude | shell-setup` — shared
  terminals on the Mac.
- `./dev.sh install` — release APK onto the phone; `./dev.sh pair-adb` sends a
  pairing link over adb.
- `./dev.sh relay-deploy` — rebuild and restart the relay on the box (own port
  8460; never touches :443).
- `./dev.sh app-test`, `app-analyze`, `go-check`, `log`.

## On the Mac

- One agent per Mac: either the brew service or the LaunchAgent
  (`uniai install`), never both. A second copy waits for the first one,
  and `uniai status` shows which one runs.
- macOS shows a "background item added" notice once for the LaunchAgent.
- Desktop/Documents/Downloads need Full Disk Access for the agent binary
  (`~/Library/Application Support/Uniai/uniai`) in System Settings →
  Privacy & Security → Full Disk Access.
- Lid closed: `sudo pmset -a disablesleep 1` (the app's Mac status sheet has a
  switch that types it into a terminal); `0` undoes it.
