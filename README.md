# Mac Remote

A personal Android app that gives the phone a terminal and the files of a Mac,
next to the Claude Code app.

```
phone ──WSS──▶ relay (your.server:8460) ◀──WSS── macremote agent (Mac)
        └──────────── Noise_IK end-to-end ─────────────┘
```

- **Relay** (`cmd/relay`, Docker on the server): a dumb pipe that pairs one
  phone socket with the Mac socket of the same room. TLS 1.3 with a self-signed
  certificate; both ends pin sha256(cert DER). It never sees plaintext.
- **Agent** (`cmd/macremote`, LaunchAgent): dials out to the relay, so the Mac
  needs no open port and no setup. Phones are authorized by their Noise static
  key; `macremote pair` issues a one-time token (10 min) as a QR/text code.
  Shells live in the agent and outlive the phone's connection.
- **App** (`app/`, Flutter): Noise_IK_25519_ChaChaPoly_SHA256 (prologue
  `macremote/1`, tested against flynn/noise vectors), xterm terminal tabs,
  file browser and code editor (re_editor), biometric lock.

Wire format, framing and RPC methods: the header of `cmd/macremote/session.go`
and `app/lib/net/link.dart`.

## Commands

`./dev.sh` lists everything. Common ones:

- `./dev.sh agent-install` — build the agent, init it against the relay, install
  the LaunchAgent and link `~/.local/bin/macremote`.
- `macremote pair | devices | revoke <n> | status` — on the Mac.
- `./dev.sh install` — release APK onto the phone; `./dev.sh pair-adb` sends a
  pairing link over adb.
- `./dev.sh relay-deploy` — rebuild and restart the relay on the box (own port
  8460; never touches :443).
- `./dev.sh app-test`, `app-analyze`, `go-check`, `log`.

## On the Mac

- macOS shows a "background item added" notice once for the LaunchAgent.
- Desktop/Documents/Downloads need Full Disk Access for the agent binary
  (`~/Library/Application Support/MacRemote/macremote`) in System Settings →
  Privacy & Security → Full Disk Access.
- Lid closed: `sudo pmset -a disablesleep 1` (the app's Mac status sheet has a
  switch that types it into a terminal); `0` undoes it.
