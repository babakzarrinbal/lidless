# bz-uniai: working notes for coding agents

CLAUDE.md imports this file. Read README.md for what the product is,
**docs/architecture.md for how it works** (holders, shared terminals, the
protocols, the traps), docs/dev-setup.md to set up a new Mac, and
docs/hosting.md for the relay. **docs/native-app.md is where it is going**
(native app on every platform, plugins, phases): new work follows its layout.

## Rule one: cheap for an AI to change, debug and improve

This is the project's most important property. Weigh every change by it, and
leave code easier for the next agent than you found it:

- **Find it fast.** One concern per file and one module per folder. Each file
  opens with a short comment saying what it owns and which doc covers it.
  Aim for files under ~300 lines. When a file grows past that, split it.
- **Every module has a map.** Each package or folder has a short README (one
  screen) with: what it does, its entry points, its tests, and its traps.
  When files move, update the Layout table below in the same commit.
- **One command proves it.** Each module can be checked alone through
  `dev.sh`, and the check prints one PASS/FAIL line. Full output goes to
  `build/logs/`. If an agent has to type a raw toolchain command, add a
  subcommand to `dev.sh` instead.
- **Tests sit beside the code they cover.** A bug fix lands together with a
  test that fails without it. Prefer fast tests that need no phone, Mac or
  relay.
- **Debug from logs, not from devices.** Every log line starts with its
  module (`term:`, `chat:`, `link:`, …), so a grep isolates one module.
  Errors say what to do next.
- **Contracts live in one place.** The wire format, RPC methods and events
  are written down once (docs/architecture.md and session.go's header), and
  both sides follow that text.
- **Plain over clever.** Explicit code, no hidden magic, no deep inheritance,
  few dependencies. A newcomer reading one file should not need five others.

**This repo is public.** Never commit the relay's address or IP, its
certificate pin, keys, or tokens. Those live in untracked files (listed below).

## Layout

| Path | What |
|---|---|
| `cmd/uniai/` | Go agent on the Mac. `session.go`: Noise handshake, wire format (header comment), RPC switch. `hold.go`: the holder process that owns each terminal's pty and serves it on a unix socket (protocol in docs/architecture.md). `term.go`: the agent's side: adopts holders, mirrors their output for phones, sends `{"ev":"terms"}`. `attach.go`: laptop CLI (`ls`, `attach`, `kill`, `claude`/`copilot`, `shell-setup`). `chat.go`/`claude.go`/`copilot.go`: reading Claude/Copilot transcripts. `vscode.go`: VS Code Copilot Chat files; `vscodemirror.go`: a chat carried on in a shared terminal is mirrored back into VS Code's chat file, and the bz-uniai VS Code extension (`vscode-ext/`, embedded, installed by `uniai vscode` or at the first handoff) opens that terminal in VS Code. `shell.go`: shell list and default. `lock.go`: one agent per Mac. `setup.go`: `uniai setup`. `main.go`: CLI, LaunchAgent install. |
| `cmd/relay/` | Go relay (Docker on the server, port 8460). A dumb pipe: per-IP rate limit (burst 15, 1 per 2 s), 8 phones per room, 10 s accept timeout. Close codes: 4404 Mac offline, 4408 Mac did not answer, 4429 too many, 4001 agent replaced. |
| `cmd/noisevec/` | Generates `app/test/noise_vectors.json` (`./dev.sh vectors`). |
| `app/` | Flutter Android app (`org.zarrinbal.uniai`, shown as "bz-uniai"). `lib/net/link.dart`: connection, reconnect, RPC. `lib/net/store.dart`: pairings (one phone key per Mac, nickname). `lib/model/terms.dart`: terminal list per Mac, live-synced on `terms` events. `lib/ui/`: screens (`home`, `session_view`, `new_session`, `macs`, `shells`, `terminal_panel`, `files_panel`, `chat_view`…). |
| `packaging/homebrew/` | Formula template; `./dev.sh brew` fills it in. Tap: github.com/babakzarrinbal/homebrew-uniai. |
| `deploy/` | Relay Dockerfile + compose; `deploy/site/` is the landing page's nginx. |
| `site/` | Landing page (uniai.zarrinbal.org); `site-build` refuses to ship a server address. |

RPC methods (agent `session.go`, about line 540): `term.*` (list, open, attach,
detach, resize, seen, rename, close; park/unpark only for terminals an old app
parked), `chat.*` (read, older, sessions, recent, commands, stop; transcript reads a VS Code Copilot Chat, listed only when the app passes `vscode: true`; handoff writes one out for Copilot/Claude in a shared terminal to carry on), `fs.*`,
`shell.list`/`shell.set`, `sys.status`, `usage`, `tokens.reset`. Events:
`terms` (a terminal came or went, on any device), `term.exit`, `term.size`
(the pty was resized: the redraw that follows is not news), `term.seen` (a
phone showed a terminal up to an offset: read on every phone). A new method needs both sides. The app must handle an
older agent (an `RpcError` with code `unknown`), because Macs update separately
through brew.

## Commands (always through dev.sh; Go runs in Docker, no Go on the host)

```bash
./dev.sh doctor                 # is this Mac ready to build? (tools, keystore, .server.env, box ssh)
./dev.sh go-check               # tidy, fmt, vet (linux+darwin), go test
./dev.sh go <args…>             # any go command in Docker (go get, go test -run X ./cmd/uniai)
./dev.sh app-analyze            # zero issues is the baseline
./dev.sh app-test [test/x.dart] # one PASS/FAIL line; full log build/logs/app-test.log
./dev.sh agent                  # bin/uniai (darwin/arm64)
./dev.sh agent-install          # build + install as this Mac's LaunchAgent (restarts the agent; terminals survive)
./dev.sh apk | install | run    # release APK; install onto the Samsung (ANDROID_SERIAL overrides)
./dev.sh log                    # agent log tail (~/Library/Logs/uniai.log)
```
Running `./dev.sh` with no command lists the rest. Output is already a summary; full logs go to `build/logs/`.

Before every commit, run `go-check`, `app-analyze` and `app-test`.

## Rules

- **Ask first** before anything that publishes: `git push`, `brew-publish`,
  `relay-deploy`, `site-deploy`, `site-dns`. Small local commits after each
  finished step are fine.
- **`agent-install` restarts this Mac's agent.** Terminals live in holder
  processes and survive it; phones reconnect within seconds. The exception is
  the first switch from a pre-holder agent (before 2026-10-01): its terminals
  end with it. Check your own ancestry (`ps -o ppid=` up the chain) before you
  restart an agent you may be running inside.
- **Holders outlive upgrades**: keep the holder protocol backward compatible
  (docs/architecture.md, "Holder protocol").
- **One agent per Mac.** The agent runs either as a brew service
  (`sh.brew.uniai`; older Homebrew: `homebrew.mxcl.uniai`) or as the LaunchAgent (`org.zarrinbal.uniai`,
  from `uniai install` / `agent-install`), never both. Two copies share a
  room and replace each other on the relay every ~2 s, so every phone drops.
  `lock.go` now makes a second copy wait, and `install` refuses next to a brew
  service. To switch a brew Mac to the dev build:
  `brew services stop uniai && ./dev.sh agent-install`.
- **Secrets are never printed, committed or copied:**
  - `.server.env` (`RELAY_HOST`) and `~/.config/uniai/agent.json` (keys,
    room key);
  - `~/.android/debug.keystore`, `~/.config/cloud/cf.env`;
  - the relay's data volume on the box.
- **On the box:** only the relay (`/opt/uniai`, :8460) and the site
  (`/opt/uniai-site`, :8462, from the old name) are ours. Never bind :443, and never touch
  xray/tailscale/networking there. Read logs with
  `ssh root@$RELAY_HOST docker logs --since 30m uniai-relay`, and mask IPs
  in anything you paste.
- **Phones:** don't drive a phone (taps, installs) while the user is on it.
  Debug from code and logs first; screenshots are a last resort. The release
  app doesn't log link errors, so the relay log plus the agent log are the
  evidence.
- **Copilot:** check `which -a copilot` before running it. VS Code's shim can
  loop and fork-bomb; the agent starts the real CLI.

## Debugging "the phone can't connect"

1. Run `./dev.sh log`: do "connected: … from <ip>" lines appear? If the phone
   never arrives, the problem is at the relay or the phone.
2. Read the relay log (above). Rapid `agent down`/`agent up` pairs for one room
   mean two agents on that Mac (see "One agent per Mac"). `pipe open/close`
   lines show phone sessions and byte counts. If the room never shows up, the
   phone is being rate-limited or is offline.
3. On the other Mac, `uniai status` reports a LaunchAgent, a brew service,
   or both.

## Working with the owner (Babak)

- Messages are often voice-dictated: read typos charitably.
- Replies: short, outcome first. Put every command the user should run in a
  fenced ```bash block, ready to copy, with commands for another machine in
  their own labelled block.
- Act through tools yourself; when blocked, say exactly how to unblock.
- Commit small steps locally without asking; push and publish only on an
  explicit ask.

## Open threads (2026-10-01)

- **Released through brew as 2026.10.01.3** (shell choice, Manage Macs agent
  side, one-agent lock, `sh.brew.*` label). The other Mac still needs:
  ```bash
  brew update && brew upgrade uniai && brew services restart uniai
  brew upgrade --cask --greedy copilot-cli
  ```
- **Copilot resume fails** ("Session file is corrupted … unknown event type")
  when Homebrew's `copilot-cli` is older than the copy VS Code bundles. It is
  an auto-updating cask, so plain `brew upgrade` skips it; use `--greedy`.
  Evidence: `~/.copilot/logs/`.
- **The other Mac (brew) runs two agents** after a `uniai install`. Fix:
  ```bash
  uniai uninstall && brew services restart uniai
  ```
- Brew service log: `/opt/homebrew/var/log/uniai.log` (`./dev.sh log`
  reads the LaunchAgent's).
- **Shared terminals (holders) run on this Mac and the phones, not yet in
  brew.** An `agent-install` kept all holders. The other Mac still runs the
  pre-holder agent until `./dev.sh brew-publish 2026.10.01.4` and a
  `brew upgrade` there. Still to check on a phone: a `claude` started in a
  laptop window shows up within a second.
- Phones run app 0.2.0 built from 96e4b9d. Still to check on a phone: the
  Recent page right after opening a Mac.
