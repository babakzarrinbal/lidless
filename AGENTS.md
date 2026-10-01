# Lidless (Mac Remote): working notes for coding agents

CLAUDE.md imports this file. Read README.md for what the product is,
docs/dev-setup.md to set up a new Mac, and docs/hosting.md for the relay.

**This repo is public.** Never commit the relay's address or IP, its
certificate pin, keys, or tokens. Those live in untracked files (listed below).

## Layout

| Path | What |
|---|---|
| `cmd/macremote/` | Go agent on the Mac. `session.go`: Noise handshake, wire format (header comment), RPC switch. `term.go`: PTY terminals that outlive the phone. `chat.go`/`claude.go`/`copilot.go`: reading Claude/Copilot transcripts. `shell.go`: shell list and default. `lock.go`: one agent per Mac. `setup.go`: `macremote setup`. `main.go`: CLI, LaunchAgent install. |
| `cmd/relay/` | Go relay (Docker on the server, port 8460). A dumb pipe: per-IP rate limit (burst 15, 1 per 2 s), 8 phones per room, 10 s accept timeout. Close codes: 4404 Mac offline, 4408 Mac did not answer, 4429 too many, 4001 agent replaced. |
| `cmd/noisevec/` | Generates `app/test/noise_vectors.json` (`./dev.sh vectors`). |
| `app/` | Flutter Android app (`org.zarrinbal.macremote`, shown as "Lidless"). `lib/net/link.dart`: connection, reconnect, RPC. `lib/net/store.dart`: pairings (one phone key per Mac, nickname). `lib/model/terms.dart`: terminal list per Mac. `lib/ui/`: screens (`home`, `session_view`, `new_session`, `macs`, `shells`, `terminal_panel`, `files_panel`, `chat_view`…). |
| `packaging/homebrew/` | Formula template; `./dev.sh brew` fills it in. Tap: github.com/babakzarrinbal/homebrew-macremote. |
| `deploy/` | Relay Dockerfile + compose; `deploy/site/` is the landing page's nginx. |
| `site/` | Landing page (lidless.zarrinbal.org); `site-build` refuses to ship a server address. |

RPC methods (agent `session.go`, about line 540): `term.*` (list, open, attach,
detach, resize, rename, close, park, unpark), `chat.*` (read, sessions,
recent, commands, stop), `fs.*`, `shell.list`/`shell.set`, `sys.status`,
`usage`, `tokens.reset`. A new method needs both sides. The app must handle an
older agent (an `RpcError` with code `unknown`), because Macs update separately
through brew.

## Commands (always through dev.sh; Go runs in Docker, no Go on the host)

```bash
./dev.sh doctor                 # is this Mac ready to build? (tools, keystore, .server.env, box ssh)
./dev.sh go-check               # tidy, fmt, vet (linux+darwin), go test
./dev.sh app-analyze            # zero issues is the baseline
./dev.sh app-test [test/x.dart] # one PASS/FAIL line; full log build/logs/app-test.log
./dev.sh agent                  # bin/macremote (darwin/arm64)
./dev.sh agent-install          # build + install as this Mac's LaunchAgent (RESTARTS the agent)
./dev.sh apk | install | run    # release APK; install onto the Samsung (ANDROID_SERIAL overrides)
./dev.sh log                    # agent log tail (~/Library/Logs/macremote.log)
```
Running `./dev.sh` with no command lists the rest. Output is already a summary; full logs go to `build/logs/`.

Before every commit, run `go-check`, `app-analyze` and `app-test`.

## Rules

- **Ask first** before anything that publishes: `git push`, `brew-publish`,
  `relay-deploy`, `site-deploy`, `site-dns`. Small local commits after each
  finished step are fine.
- **`agent-install` restarts this Mac's agent**, and that kills every terminal
  it runs. If the user is working through the phone (even a Claude session
  driving this very repo), say so and ask before running it.
- **One agent per Mac.** The agent runs either as a brew service
  (`homebrew.mxcl.macremote`) or as the LaunchAgent (`org.zarrinbal.macremote`,
  from `macremote install` / `agent-install`), never both. Two copies share a
  room and replace each other on the relay every ~2 s, so every phone drops.
  `lock.go` now makes a second copy wait, and `install` refuses next to a brew
  service. To switch a brew Mac to the dev build:
  `brew services stop macremote && ./dev.sh agent-install`.
- **Secrets are never printed, committed or copied:**
  - `.server.env` (`RELAY_HOST`) and `~/.config/macremote/agent.json` (keys,
    room key);
  - `~/.android/debug.keystore`, `~/.config/cloud/cf.env`;
  - the relay's data volume on the box.
- **On the box:** only the relay (`/opt/macremote`, :8460) and the site
  (`/opt/lidless`, :8462) are ours. Never bind :443, and never touch
  xray/tailscale/networking there. Read logs with
  `ssh root@$RELAY_HOST docker logs --since 30m macremote-relay`, and mask IPs
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
3. On the other Mac, `macremote status` reports a LaunchAgent, a brew service,
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

- **Not yet released through brew:**
  - per-terminal and per-Mac shell choice (`shell.list`/`shell.set`);
  - the Manage Macs page's agent side;
  - the one-agent lock.

  Until `./dev.sh brew-publish` runs, the other Mac's shell picker says
  "Update Lidless on the Mac". Then, on that Mac:
  ```bash
  brew update && brew upgrade macremote && brew services restart macremote
  ```
- **The other Mac (brew) runs two agents** after a `macremote install`. Fix:
  ```bash
  macremote uninstall && brew services restart macremote
  ```
- `origin/main` is behind local: pushing needs the owner's go-ahead.
- Phones run app 0.2.0 built from 96e4b9d. Still to check on a phone: the
  Recent page right after opening a Mac.
