# bz-uniai everywhere: the native app plan

Where bz-uniai is going: one native app on Mac, Android, iOS, Windows and
Linux. Every device that can host AI sessions is the **master** of its own
sessions, and a **client** of every device it is paired with. How the current
system works: [architecture.md](architecture.md).

Decided 2026-10-02:

- **Flutter for the UI, a Go core for everything else.** Flutter compiles to
  native code on all five platforms, and device APIs it lacks come through
  platform channels (Swift on Apple, Kotlin on Android). The existing app is
  the starting point; it gains desktop targets.
- **The core is a daemon, bundled with the app.** On a Mac the `.app` carries
  the core binary and registers it as a login item (SMAppService). Quitting
  the app keeps sessions running and reachable from other devices, just as
  holders outlive the agent today.
- **This repo, restructured step by step.** Brew users and running holders
  keep working throughout.
- **Public, one app that bundles everything; no brew** (brew stays only until
  the app replaces it on our own Macs). The app installs and updates the core
  itself, and offers the `uniai` command line the way VS Code offers
  `code` (a menu item that links it into the PATH).
- **Name: bz-uniai** ("bz-uniai: AI Code Anywhere" in the stores), with its page at
  uniai.zarrinbal.org (a subdomain we own, so nothing to register).
  The `bz-` prefix keeps it apart from other "UniAI" products. Only what users see is renamed: the
  package `org.zarrinbal.macremote`, `~/.config/macremote`, the Noise prologue,
  the LaunchAgent labels, the VS Code extension id (`zarrinbal.lidless`) and the
  box's `/opt/lidless` keep their names, so pairings and installs survive.

## Shipping it publicly

| Platform | Channel | Role | Why |
|---|---|---|---|
| macOS | Developer ID signed, notarized DMG from the site; Sparkle updates | master + client | The Mac App Store sandbox forbids spawning shells and reading `~/.claude`. A client-only App Store build is possible later. |
| Android | Play Store (client); master later | client first | Play and Android 10+ forbid running binaries downloaded into app storage (why Termux left Play). A core shipped inside the APK as a native lib may run; Claude/Copilot need Node, which hits that rule. |
| iOS | App Store | client | No processes on iOS. |
| Windows | signed installer (MSIX or Inno), winget later | master + client | |
| Linux | AppImage / .deb, Flatpak later | master + client | |

- **The AI CLIs are not bundled.** Claude Code and the Copilot CLI are the
  user's own installs, under their own licences and logins. The app finds
  them, offers the official installer when one is missing, and reads the
  user's own usage.
- **Accounts:** Apple Developer Program (Developer ID, notarization, App
  Store), Google Play developer account.
- **The relay** becomes a public service: real TLS certificates instead of a
  pinned self-signed one, per-room abuse limits, and a self-host option
  (the setting stays). End-to-end Noise means it still never sees plaintext.
  Devices on the same network should talk directly, with the relay as the
  fallback.

## The model

```
Device (core)                       one per machine, the master of what's below
 └ Workspace                        a root folder
    ├ Session  (AI)                 claude | copilot: conversation id, state, usage, tokens
    ├ Terminals                     holders: the AI's own and any number of shells
    └ Plugin state                  git repos under the root, later pipelines, tickets, pods…
```

- A **workspace** is the folder an AI session opened on. Everything a plugin
  shows is relative to it: the file explorer starts there (and can leave it,
  with the root one tap away), git finds the repos under it.
- A **session** is first class in the core: kind, conversation, state
  (`active` working, `waiting` for you, `idle`, `ended`), usage and tokens.
  Today it is only a string tag on terminals and the phone works the state out
  from the screen. The core owns it and pushes `session.*` events, so every
  device and every plugin see the same thing.

## One app, two roles

```
┌──────────────── a device ────────────────┐
│ Flutter app ──── relay, Noise_IK ────────┼──▶ other devices' cores
│     │ local socket (no relay)            │
│     ▼                                    │
│ core daemon (Go) ◀── relay, Noise_IK ────┼─── other devices' apps
│  workspaces · sessions · holders         │
│  plugins: fs, term, git, … (RPC + MCP)   │
└──────────────────────────────────────────┘
```

The app speaks the same RPCs to its own core and to a remote one; only the
transport differs (`Link` gets a local-socket transport beside the relay one).

| Platform | Master | Client | Note |
|---|---|---|---|
| macOS | first | first | |
| Android | later | first | A shell is easy (Go pty). Claude and Copilot need Node, through Termux. |
| Linux | easy | yes | Same core as the Mac. |
| Windows | work | yes | Holders need ConPTY and named pipes. |
| iOS | no | yes | iOS forbids starting processes, so no real Claude or shell. |

## Plugins

A plugin has two halves:

- **Core** (Go, `internal/plugins/<name>`): registers methods in its namespace
  (`git.status`). Each method describes itself: a one-line description, a JSON
  schema for its parameters, and whether it changes anything (`Write`). The
  registry is in `internal/plugin`; `plugins.list` tells an app what this core
  offers, so an app can work with an older core.
- **UI** (Dart, `app/lib/plugins/<name>`): a panel bound to a workspace. It
  becomes a package under `packages/` once a second app or outside author needs
  it, not before.

Because the methods describe themselves, the core can serve the same registry
as an **MCP server**. A Claude or Copilot session started in a workspace then
gets the plugins as tools (`git_status`, later `jira_search`, `k8s_pods`)
without plugin code for the AI side. `Write` methods are the ones an AI must
ask before calling. Plugin credentials (Jira, Azure DevOps, kube contexts) stay
in the core of the device that owns them; clients never see them.

First plugins: `fs` (exists), `term` (exists, the holders), `git` (new:
repos under the root, status, log, diff; read-only at first). Later: Azure
DevOps pipelines, Jira, Confluence, Kubernetes, Argo.

## Layout

The Go module stays at the root; packages move out of `cmd/macremote` as
they are touched.

```
cmd/macremote      daemon + CLI (the core)        cmd/relay, cmd/noisevec
internal/plugin    registry: Method, Ctx, plugins.list
internal/plugins/  git, later fs, term, ado, jira, k8s…
app/               the Flutter app: android, ios, macos (then windows, linux)
  lib/net          protocol: Noise, Link, transports
  lib/model        workspaces, sessions, terminals
  lib/plugins/     plugin panels
  lib/ui           shells: phone layout, desktop layout
```

## Phases

1. **Plugin registry in the core**, with `git` as the first plugin on it.
   `session.go` falls back to the registry for methods its switch lacks.
2. **Workspace and session registry in the core**: sessions with state and
   usage, `session.*` events; the app reads them instead of guessing.
3. **The macOS app**: the `macos` target, a desktop layout (workspace sidebar,
   session tabs, panels side by side), a local transport to its own core, the
   bundled core as a login item, and connections to other Macs through the
   relay. Pairing becomes device to device, not only phone to Mac.
4. **Android on the same code**: the phone layout over the shared model and
   plugins.
5. **MCP bridge**: the plugin registry as tools for the AI sessions; then the
   integration plugins; then Windows, Linux and the iOS client; Android as a
   master last.
