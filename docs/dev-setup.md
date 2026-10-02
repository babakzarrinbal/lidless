# Setting up a Mac to work on bz-uniai

Clone the repo, install the toolchain, copy three untracked files over, then
check with `./dev.sh doctor`.

## 1. Clone

```bash
mkdir -p ~/Projects && cd ~/Projects
git clone git@github.com:babakzarrinbal/lidless.git mac-remote
cd mac-remote
```

## 2. Toolchain

- **Go** runs in Docker (`golang:1.26`), so there's no Go on the host.
- **Flutter** lives at `~/tools/flutter` (stable channel, 3.47 when this was
  written).
- **Java and the Android SDK** are at the paths `dev.sh` exports.

```bash
brew install gh jq
brew install --cask docker temurin@17 android-commandlinetools android-platform-tools
yes | sdkmanager --licenses >/dev/null
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"
mkdir -p ~/tools && git clone -b stable --depth 1 https://github.com/flutter/flutter.git ~/tools/flutter
~/tools/flutter/bin/flutter config --android-sdk /opt/homebrew/share/android-commandlinetools
gh auth login
```
Start Docker Desktop once, so the `docker` command works.

## 3. Files that are not in git (copy them from the old Mac)

| File | Why | Without it |
|---|---|---|
| `.server.env` (repo root) | `RELAY_HOST=<the server>`, for the relay and site commands | Commands that touch the box stop with a hint |
| `~/.android/debug.keystore` | Release APKs are signed with it | The phones refuse the update (signature mismatch); reinstalling wipes their pairings |
| `~/.config/cloud/cf.env` | Cloudflare token, only for `site-dns` | Only `site-dns` fails |

Copy them by AirDrop or USB to the same paths. Never commit them or paste
their contents anywhere.

**SSH to the box** (relay logs and deploys): add the new Mac's public key to
the server's `authorized_keys`. Run this on the **old Mac**, after copying the
new Mac's `~/.ssh/id_ed25519.pub` over as `new.pub`:
```bash
cd ~/Projects/mac-remote && . ./.server.env && ssh root@$RELAY_HOST 'cat >> ~/.ssh/authorized_keys' < new.pub
```

## 4. Check

```bash
./dev.sh doctor
./dev.sh go-check && ./dev.sh app-analyze && ./dev.sh app-test
```

## 5. Phones (wireless adb, same Wi-Fi)

On the phone, open Developer options › Wireless debugging › Pair with code.
Then, on the Mac:
```bash
adb pair <phone-ip>:<pair-port>
adb connect <phone-ip>:<port>
adb devices
```
`dev.sh` finds the Samsung's current port by itself. For another phone, set
`ANDROID_SERIAL=<ip:port>` in front of `./dev.sh install`.

## 6. The agent on this Mac

A Mac set up with brew already runs the released agent as a brew service.
That is enough for working on the app. To run the agent built from this
checkout instead, stop the brew service first, because only one copy may run:
```bash
brew services stop macremote
./dev.sh agent-install
```
The config in `~/.config/macremote/` is shared, so paired phones stay paired.
To go back:
```bash
macremote uninstall && brew services start macremote
```
