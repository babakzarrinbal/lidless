#!/usr/bin/env bash
# Mac Remote dev harness. Go builds run in Docker (no Go on the host);
# the Flutter app uses ~/tools/flutter. Full logs go to build/logs/.
#
#   ./dev.sh go-check              go vet + tests (Docker)
#   ./dev.sh agent                 build bin/macremote (darwin/arm64)
#   ./dev.sh agent-install         build, init against the relay, install the LaunchAgent
#   ./dev.sh mac-kit               build/MacRemote.zip: agent + install.sh for another Mac
#   ./dev.sh brew [version]        build/brew/: release tarballs + Homebrew formula (BREW_URL=… where they'll be hosted)
#   ./dev.sh brew-test             install that formula from a local tap, check it, remove it
#   ./dev.sh brew-publish [version] build, then a GitHub release + the formula in the tap ($BREW_OWNER/homebrew-macremote, via gh)
#   ./dev.sh relay-deploy          build + (re)start the relay on the server (:8460)
#   ./dev.sh relay-pin             print the relay certificate pin
#   ./dev.sh vectors               regenerate app/test/noise_vectors.json
#   ./dev.sh app-test              flutter test
#   ./dev.sh app-analyze           flutter analyze
#   ./dev.sh apk                   release APK
#   ./dev.sh install               release APK → the Samsung (ANDROID_SERIAL overrides)
#   ./dev.sh run                   install + launch + follow logs
#   ./dev.sh pair-adb              send a fresh pairing link to the phone over adb
#   ./dev.sh log                   tail the agent log
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD

BOX=root@your.server
RELAY_PORT=8460
BREW_OWNER=${BREW_OWNER:-babakzarrinbal}
BREW_TAP=$BREW_OWNER/homebrew-macremote
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="$HOME/tools/flutter/bin:/opt/homebrew/bin:$PATH"
# The Samsung's wireless adb port changes on every reconnect: take whichever is attached.
samsung() { adb devices 2>/dev/null | awk '/^192\.168\.2\.118:[0-9]+\tdevice/ {print $1; exit}'; }
export ANDROID_SERIAL=${ANDROID_SERIAL:-$(samsung)}
APP_ID=org.zarrinbal.macremote
LOGS=$ROOT/build/logs
mkdir -p "$LOGS" bin

gorun() { # gorun GOOS GOARCH cmd…
  local os=$1 arch=$2; shift 2
  docker run --rm -v "$ROOT":/src -v macremote-go:/go -w /src \
    -e GOOS="$os" -e GOARCH="$arch" -e CGO_ENABLED=0 golang:1.26 "$@"
}

quiet() { # quiet name cmd… → one line, full log on failure
  local name=$1; shift
  local log=$LOGS/$name.log
  if "$@" >"$log" 2>&1; then echo "PASS $name"; else echo "FAIL $name (log: $log)"; tail -n 30 "$log"; return 1; fi
}

cmd_go-check() {
  quiet go-tidy gorun linux arm64 go mod tidy
  quiet go-fmt gorun linux arm64 gofmt -l -w cmd
  quiet go-vet-linux gorun linux arm64 go vet ./...
  quiet go-vet-darwin gorun darwin arm64 go vet ./cmd/macremote
  quiet go-test gorun linux arm64 go test ./...
}

cmd_agent() {
  quiet agent-build gorun darwin arm64 go build -trimpath -ldflags=-s -o bin/macremote ./cmd/macremote
  ls -la bin/macremote | awk '{print "bin/macremote", $5, "bytes"}'
}

# A zip for another Mac (no repo, Docker or Go there): both binaries and an
# install script that inits against the relay, installs the LaunchAgent and
# shows a pairing QR code.
cmd_mac-kit() {
  local kit=build/MacRemote pin
  pin=$(cmd_relay-pin)
  rm -rf "$kit" && mkdir -p "$kit"
  quiet agent-arm64 gorun darwin arm64 go build -trimpath -ldflags=-s -o "$kit/macremote-arm64" ./cmd/macremote
  quiet agent-amd64 gorun darwin amd64 go build -trimpath -ldflags=-s -o "$kit/macremote-x86_64" ./cmd/macremote
  cat > "$kit/install.sh" <<EOF
#!/bin/sh
# Mac Remote agent: in Terminal run  sh ~/Downloads/MacRemote/install.sh
set -e
cd "\$(dirname "\$0")"
bin=./macremote-\$(uname -m)
xattr -c "\$bin" 2>/dev/null || true
chmod +x "\$bin"
[ -f "\$HOME/.config/macremote/agent.json" ] || "\$bin" init -relay your.server:$RELAY_PORT -pin $pin
"\$bin" install
mkdir -p "\$HOME/.local/bin"
ln -sf "\$HOME/Library/Application Support/MacRemote/macremote" "\$HOME/.local/bin/macremote"
echo; echo "Installed. Scan this code with the Mac Remote app (Pair another Mac):"; echo
"\$HOME/Library/Application Support/MacRemote/macremote" pair
EOF
  (cd build && rm -f MacRemote.zip && zip -qr MacRemote.zip MacRemote)
  ls -la build/MacRemote.zip | awk '{print "build/MacRemote.zip", $5, "bytes"}'
}

cmd_brew() {
  local v=${1:-$(date +%Y.%m.%d)} out=build/brew pin
  local url=${BREW_URL:-https://github.com/$BREW_TAP/releases/download/v$v}
  pin=$(cmd_relay-pin)
  rm -rf "$out" && mkdir -p "$out"
  local flags="-s -X main.defaultRelay=your.server:$RELAY_PORT -X main.defaultPin=$pin"
  local arch sha_arm sha_intel
  for arch in arm64 amd64; do
    mkdir -p "$out/$arch"
    quiet "brew-$arch" gorun darwin $arch go build -trimpath -ldflags="$flags" -o "$out/$arch/macremote" ./cmd/macremote
    tar -C "$out/$arch" -czf "$out/macremote-$v-darwin-$arch.tar.gz" macremote
  done
  sha_arm=$(shasum -a 256 "$out/macremote-$v-darwin-arm64.tar.gz" | cut -d' ' -f1)
  sha_intel=$(shasum -a 256 "$out/macremote-$v-darwin-amd64.tar.gz" | cut -d' ' -f1)
  python3 - "$v" "$url" "$sha_arm" "$sha_intel" "https://github.com/$BREW_TAP" <<'PY' > "$out/macremote.rb"
import sys
v, url, arm, intel, home = sys.argv[1:]
t = open("packaging/homebrew/macremote.rb.in").read()
for k, x in {"@VERSION@": v, "@HOMEPAGE@": home, "@URL_ARM@": f"{url}/macremote-{v}-darwin-arm64.tar.gz", "@SHA_ARM@": arm,
             "@URL_INTEL@": f"{url}/macremote-{v}-darwin-amd64.tar.gz", "@SHA_INTEL@": intel}.items():
    assert k in t, k
    t = t.replace(k, x)
sys.stdout.write(t)
PY
  ls "$out"/*.tar.gz "$out/macremote.rb" | sed 's/^/  /'
}

cmd_brew-test() { # a throwaway local tap with file:// URLs; leaves nothing behind
  local tap=macremote/local dir
  BREW_URL="file://$ROOT/build/brew" cmd_brew test
  brew tap-new --no-git "$tap" >/dev/null
  dir=$(brew --repository "$tap")
  cp build/brew/macremote.rb "$dir/Formula/"
  local rc=0
  quiet brew-install brew install "$tap/macremote" || rc=1
  [ $rc = 0 ] && { quiet brew-formula-test brew test "$tap/macremote" || rc=1; }
  [ $rc = 0 ] && { "$(brew --prefix)/opt/macremote/bin/macremote" 2>&1 | head -1 | sed 's/^/  /' || true; }
  brew uninstall --formula "$tap/macremote" >/dev/null 2>&1 || true
  brew untap "$tap" >/dev/null 2>&1 || true
  brew developer off >/dev/null 2>&1 || true # tap-new turned it on
  return $rc
}

cmd_brew-publish() { # the official tap: tarballs on a release, the formula in Formula/
  local v=${1:-$(date +%Y.%m.%d)} f=Formula/macremote.rb sha
  gh repo view "$BREW_TAP" >/dev/null 2>&1 ||
    gh repo create "$BREW_TAP" --public -d "Homebrew tap for Mac Remote: your Mac's terminals, files and Claude Code on your phone" >/dev/null
  cmd_brew "$v"
  # The formula first: a release needs a commit to tag, and a new tap has none.
  sha=$(gh api "repos/$BREW_TAP/contents/$f" -q .sha 2>/dev/null || true)
  gh api -X PUT "repos/$BREW_TAP/contents/$f" -f message="macremote $v" \
    -f content="$(base64 < build/brew/macremote.rb | tr -d '\n')" ${sha:+-f sha="$sha"} >/dev/null
  if gh release view "v$v" -R "$BREW_TAP" >/dev/null 2>&1; then
    gh release upload "v$v" -R "$BREW_TAP" --clobber build/brew/*.tar.gz
  else
    gh release create "v$v" -R "$BREW_TAP" -t "macremote $v" -n "brew install $BREW_OWNER/macremote/macremote" build/brew/*.tar.gz >/dev/null
  fi
  echo "  published v$v: brew install $BREW_OWNER/macremote/macremote"
}

cmd_relay-pin() { ssh "$BOX" docker exec macremote-relay /relay pin; }

cmd_agent-install() {
  cmd_agent
  if [ ! -f "$HOME/.config/macremote/agent.json" ]; then # keep pairings on reinstall
    local pin; pin=$(cmd_relay-pin)
    bin/macremote init -relay your.server:$RELAY_PORT -pin "$pin"
  fi
  bin/macremote install
  mkdir -p "$HOME/.local/bin"
  ln -sf "$HOME/Library/Application Support/MacRemote/macremote" "$HOME/.local/bin/macremote"
}

cmd_relay-deploy() {
  quiet relay-build gorun linux amd64 go build -trimpath -ldflags=-s -o bin/relay-linux-amd64 ./cmd/relay
  ssh "$BOX" mkdir -p /opt/macremote
  scp -q bin/relay-linux-amd64 deploy/Dockerfile.relay deploy/compose.yml "$BOX":/opt/macremote/
  ssh "$BOX" 'cd /opt/macremote && docker compose up -d --build 2>&1 | tail -3 && sleep 2 && docker logs --tail 3 macremote-relay'
}

cmd_vectors() { gorun linux arm64 go run ./cmd/noisevec > app/test/noise_vectors.json && echo "wrote app/test/noise_vectors.json"; }

cmd_app-test() { (cd app && quiet app-test flutter test "$@"); } # [file…]
cmd_app-analyze() { (cd app && flutter analyze --no-pub 2>&1 | grep -E 'error|warning|info|issues found|No issues' | head -40); }

cmd_apk() {
  (cd app && quiet apk flutter build apk --release --target-platform android-arm64)
  ls -la app/build/app/outputs/flutter-apk/app-release.apk | awk '{print "app-release.apk", $5, "bytes"}'
}

cmd_install() {
  cmd_apk
  adb install -r app/build/app/outputs/flutter-apk/app-release.apk | tail -1
}

cmd_run() {
  cmd_install
  adb shell am force-stop $APP_ID
  adb shell monkey -p $APP_ID -c android.intent.category.LAUNCHER 1 >/dev/null
  adb logcat -c; adb logcat -v brief flutter:V '*:S'
}

cmd_pair-adb() {
  local code; code=$(bin/macremote pair -code)
  adb shell am start -a android.intent.action.VIEW -d "macremote://pair/$code" $APP_ID >/dev/null
  echo "pairing link sent to $ANDROID_SERIAL (valid 10 min); confirm on the phone"
}

cmd_log() { tail -n 40 "$HOME/Library/Logs/macremote.log"; }

cmd=${1:-help}; shift || true
if declare -f "cmd_$cmd" >/dev/null; then "cmd_$cmd" "$@"; else sed -n '2,/^set /p' "$0" | grep '^#'; fi
