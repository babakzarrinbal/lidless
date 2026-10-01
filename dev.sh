#!/usr/bin/env bash
# Mac Remote dev harness. Go builds run in Docker (no Go on the host);
# the Flutter app uses ~/tools/flutter. Full logs go to build/logs/.
#
#   ./dev.sh go-check              go vet + tests (Docker)
#   ./dev.sh agent                 build bin/macremote (darwin/arm64)
#   ./dev.sh agent-install         build, init against the relay, install the LaunchAgent
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
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="$HOME/tools/flutter/bin:/opt/homebrew/bin:$PATH"
export ANDROID_SERIAL=${ANDROID_SERIAL:-192.168.2.118:5555}
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
  quiet go-vet-linux gorun linux arm64 go vet ./...
  quiet go-vet-darwin gorun darwin arm64 go vet ./cmd/macremote
  quiet go-test gorun linux arm64 go test ./...
}

cmd_agent() {
  quiet agent-build gorun darwin arm64 go build -trimpath -ldflags=-s -o bin/macremote ./cmd/macremote
  ls -la bin/macremote | awk '{print "bin/macremote", $5, "bytes"}'
}

cmd_relay-pin() { ssh "$BOX" docker exec macremote-relay /relay pin; }

cmd_agent-install() {
  cmd_agent
  local pin; pin=$(cmd_relay-pin)
  bin/macremote init -relay your.server:$RELAY_PORT -pin "$pin"
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

cmd_app-test() { (cd app && quiet app-test flutter test); }
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
if declare -f "cmd_$cmd" >/dev/null; then "cmd_$cmd" "$@"; else sed -n '2,20p' "$0"; fi
