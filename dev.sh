#!/usr/bin/env bash
# bz-uniai dev harness. Go builds run in Docker (no Go on the host);
# the Flutter app uses ~/tools/flutter. Full logs go to build/logs/.
#
#   ./dev.sh doctor                is this Mac ready? (tools, untracked files, box ssh; docs/dev-setup.md)
#   ./dev.sh go-check              go vet + tests (Docker)
#   ./dev.sh go <args…>            any go command in Docker (e.g. go get, go test -run X ./cmd/uniai)
#   ./dev.sh agent                 build bin/uniai (darwin/arm64)
#   ./dev.sh agent-install         build, init against the relay, install the LaunchAgent
#   ./dev.sh mac-kit               build/Uniai.zip: agent + install.sh for another Mac
#   ./dev.sh brew [version]        build/brew/: release tarballs + Homebrew formula, generic: `uniai setup <relay>` after install
#   ./dev.sh brew-test             install that formula from a local tap, check it, remove it
#   ./dev.sh brew-publish [version] build, then a GitHub release + the formula in the tap ($BREW_OWNER/homebrew-uniai, via gh)
#   ./dev.sh relay-deploy          build + (re)start the relay on the server (:8460)
#   ./dev.sh relay-pin             print the relay certificate pin
#   ./dev.sh site-build            build/site: the bz-uniai page + the release APK
#   ./dev.sh site-deploy           build it, serve it on the box (:8462) → https://uniai.zarrinbal.org
#   ./dev.sh site-dns              once: Cloudflare A record + Origin Rule for that page
#   ./dev.sh vectors               regenerate app/test/noise_vectors.json
#   ./dev.sh app-test              flutter test
#   ./dev.sh app-analyze           flutter analyze
#   ./dev.sh icons                 render the app icon (Android, macOS, site) from app/assets/icon/*.svg
#   ./dev.sh app-pub <args…>       flutter pub (add <pkg>, get, outdated)
#   ./dev.sh apk                   release APK
#   ./dev.sh mac-app | mac-run     the Mac app (Flutter macos target), build | build + open
#   ./dev.sh install               release APK → the Samsung (ANDROID_SERIAL overrides)
#   ./dev.sh run                   install + launch + follow logs
#   ./dev.sh pair-adb              send a fresh pairing link to the phone over adb
#   ./dev.sh log                   tail the agent log
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD

# The server's address stays out of the repo: put RELAY_HOST=<ip or name> in
# .server.env (untracked).
[ -f .server.env ] && . ./.server.env
RELAY_HOST=${RELAY_HOST:-}
BOX=root@$RELAY_HOST
need_box() { [ -n "$RELAY_HOST" ] || { echo "put RELAY_HOST=<the server> in .server.env" >&2; exit 1; }; }
RELAY_PORT=8460
BREW_OWNER=${BREW_OWNER:-babakzarrinbal}
BREW_TAP=$BREW_OWNER/homebrew-uniai
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="$HOME/tools/flutter/bin:/opt/homebrew/bin:$PATH"
# The Samsung's wireless adb port changes on every reconnect: take whichever is attached.
# Not attached: connect to the ports it advertises over mDNS (Wireless debugging on).
samsung() {
  local s; s=$(adb devices 2>/dev/null | awk '/^192\.168\.2\.118:[0-9]+\tdevice/ {print $1; exit}')
  if [ -z "$s" ] && command -v adb >/dev/null; then
    for p in $(adb mdns services 2>/dev/null | awk '/_adb-tls-connect.*192\.168\.2\.118:/ {print $NF}'); do
      # a stale mDNS port makes adb connect hang forever
      perl -e 'alarm 5; exec @ARGV' adb connect "$p" 2>/dev/null | grep -q '^connected' && { s=$p; break; }
    done
  fi
  echo "$s"
}
need_phone() { export ANDROID_SERIAL=${ANDROID_SERIAL:-$(samsung)}; }
APP_ID=org.zarrinbal.uniai
LOGS=$ROOT/build/logs
mkdir -p "$LOGS" bin

gorun() { # gorun GOOS GOARCH cmd…
  local os=$1 arch=$2; shift 2
  docker run --rm -v "$ROOT":/src -v uniai-go:/go -w /src \
    -e GOOS="$os" -e GOARCH="$arch" -e CGO_ENABLED=0 golang:1.26 "$@"
}

quiet() { # quiet name cmd… → one line, full log on failure
  local name=$1; shift
  local log=$LOGS/$name.log
  if "$@" >"$log" 2>&1; then echo "PASS $name"; else echo "FAIL $name (log: $log)"; tail -n 30 "$log"; return 1; fi
}

cmd_doctor() { # read-only; prints OK/MISSING per item, never a secret's value
  local bad=0
  chk() { if eval "$2" >/dev/null 2>&1; then echo "OK      $1"; else echo "MISSING $1  → $3"; bad=1; fi; }
  chk docker "docker info" "start Docker Desktop (brew install --cask docker)"
  chk flutter "[ -x $HOME/tools/flutter/bin/flutter ]" "git clone -b stable https://github.com/flutter/flutter.git ~/tools/flutter"
  chk java17 "[ -d $JAVA_HOME ]" "brew install --cask temurin@17"
  chk android-sdk "[ -d $ANDROID_HOME/platforms ]" "brew install --cask android-commandlinetools, then sdkmanager (docs/dev-setup.md)"
  chk adb "command -v adb" "brew install --cask android-platform-tools"
  chk gh "gh auth status" "brew install gh && gh auth login"
  chk jq "command -v jq" "brew install jq"
  chk debug-keystore "[ -f $HOME/.android/debug.keystore ]" "copy ~/.android/debug.keystore from the old Mac (APK signing)"
  chk .server.env "[ -n '$RELAY_HOST' ]" "copy .server.env from the old Mac"
  [ -n "$RELAY_HOST" ] && chk box-ssh "ssh -o BatchMode=yes -o ConnectTimeout=5 $BOX true" "add this Mac's ssh key on the box (docs/dev-setup.md)"
  local la=no bs=no
  launchctl print "gui/$(id -u)/org.zarrinbal.uniai" >/dev/null 2>&1 && la=yes
  for l in sh.brew.uniai homebrew.mxcl.uniai; do
    launchctl print "gui/$(id -u)/$l" >/dev/null 2>&1 && bs=yes
  done
  echo "agent   LaunchAgent=$la brew-service=$bs$([ $la$bs = yesyes ] && echo '  ← TWO copies: keep one (AGENTS.md)')"
  echo "phones  $(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {printf "%s ", $1}')"
  return $bad
}

cmd_go-check() {
  quiet go-tidy gorun linux arm64 go mod tidy
  quiet go-fmt gorun linux arm64 gofmt -l -w cmd internal
  quiet go-vet-linux gorun linux arm64 go vet ./...
  quiet go-vet-darwin gorun darwin arm64 go vet ./...
  quiet go-test gorun linux arm64 go test ./...
}

cmd_go() { gorun linux arm64 go "$@"; }

cmd_agent() {
  quiet agent-build gorun darwin arm64 go build -trimpath -ldflags=-s -o bin/uniai ./cmd/uniai
  ls -la bin/uniai | awk '{print "bin/uniai", $5, "bytes"}'
}

# A zip for another Mac (no repo, Docker or Go there): both binaries and an
# install script that inits against the relay, installs the LaunchAgent and
# shows a pairing QR code.
cmd_mac-kit() {
  local kit=build/Uniai pin
  pin=$(cmd_relay-pin)
  rm -rf "$kit" && mkdir -p "$kit"
  quiet agent-arm64 gorun darwin arm64 go build -trimpath -ldflags=-s -o "$kit/uniai-arm64" ./cmd/uniai
  quiet agent-amd64 gorun darwin amd64 go build -trimpath -ldflags=-s -o "$kit/uniai-x86_64" ./cmd/uniai
  cat > "$kit/install.sh" <<EOF
#!/bin/sh
# bz-uniai agent: in Terminal run  sh ~/Downloads/Uniai/install.sh
set -e
cd "\$(dirname "\$0")"
bin=./uniai-\$(uname -m)
xattr -c "\$bin" 2>/dev/null || true
chmod +x "\$bin"
[ -f "\$HOME/.config/uniai/agent.json" ] || "\$bin" init -relay $RELAY_HOST:$RELAY_PORT -pin $pin
"\$bin" install
mkdir -p "\$HOME/.local/bin"
ln -sf "\$HOME/Library/Application Support/Uniai/uniai" "\$HOME/.local/bin/uniai"
echo; echo "Installed. Scan this code with the bz-uniai app (Pair another Mac):"; echo
"\$HOME/Library/Application Support/Uniai/uniai" pair
EOF
  (cd build && rm -f Uniai.zip && zip -qr Uniai.zip Uniai)
  ls -la build/Uniai.zip | awk '{print "build/Uniai.zip", $5, "bytes"}'
}

cmd_brew() {
  local v=${1:-$(date +%Y.%m.%d)} out=build/brew
  local url=${BREW_URL:-https://github.com/$BREW_TAP/releases/download/v$v}
  rm -rf "$out" && mkdir -p "$out"
  local flags="-s" # no relay built in: `uniai setup host:port` names it
  local arch sha_arm sha_intel
  for arch in arm64 amd64; do
    mkdir -p "$out/$arch"
    quiet "brew-$arch" gorun darwin $arch go build -trimpath -ldflags="$flags" -o "$out/$arch/uniai" ./cmd/uniai
    tar -C "$out/$arch" -czf "$out/uniai-$v-darwin-$arch.tar.gz" uniai
  done
  sha_arm=$(shasum -a 256 "$out/uniai-$v-darwin-arm64.tar.gz" | cut -d' ' -f1)
  sha_intel=$(shasum -a 256 "$out/uniai-$v-darwin-amd64.tar.gz" | cut -d' ' -f1)
  python3 - "$v" "$url" "$sha_arm" "$sha_intel" "https://github.com/$BREW_TAP" <<'PY' > "$out/uniai.rb"
import sys
v, url, arm, intel, home = sys.argv[1:]
t = open("packaging/homebrew/uniai.rb.in").read()
for k, x in {"@VERSION@": v, "@HOMEPAGE@": home, "@URL_ARM@": f"{url}/uniai-{v}-darwin-arm64.tar.gz", "@SHA_ARM@": arm,
             "@URL_INTEL@": f"{url}/uniai-{v}-darwin-amd64.tar.gz", "@SHA_INTEL@": intel}.items():
    assert k in t, k
    t = t.replace(k, x)
sys.stdout.write(t)
PY
  ls "$out"/*.tar.gz "$out/uniai.rb" | sed 's/^/  /'
}

cmd_brew-test() { # a throwaway local tap with file:// URLs; leaves nothing behind
  local tap=uniai/local dir
  BREW_URL="file://$ROOT/build/brew" cmd_brew test
  brew tap-new --no-git "$tap" >/dev/null
  dir=$(brew --repository "$tap")
  cp build/brew/uniai.rb "$dir/Formula/"
  local rc=0
  quiet brew-install brew install "$tap/uniai" || rc=1
  [ $rc = 0 ] && { quiet brew-formula-test brew test "$tap/uniai" || rc=1; }
  [ $rc = 0 ] && { "$(brew --prefix)/opt/uniai/bin/uniai" 2>&1 | head -1 | sed 's/^/  /' || true; }
  brew uninstall --formula "$tap/uniai" >/dev/null 2>&1 || true
  brew untap "$tap" >/dev/null 2>&1 || true
  brew developer off >/dev/null 2>&1 || true # tap-new turned it on
  return $rc
}

cmd_brew-publish() { # the official tap: tarballs on a release, the formula in Formula/
  local v=${1:-$(date +%Y.%m.%d)} f=Formula/uniai.rb sha
  gh repo view "$BREW_TAP" >/dev/null 2>&1 ||
    gh repo create "$BREW_TAP" --public -d "Homebrew tap for bz-uniai: your Mac's terminals, files and Claude Code on your phone" >/dev/null
  cmd_brew "$v"
  # The formula first: a release needs a commit to tag, and a new tap has none.
  sha=$(gh api "repos/$BREW_TAP/contents/$f" -q .sha 2>/dev/null || true)
  gh api -X PUT "repos/$BREW_TAP/contents/$f" -f message="uniai $v" \
    -f content="$(base64 < build/brew/uniai.rb | tr -d '\n')" ${sha:+-f sha="$sha"} >/dev/null
  if gh release view "v$v" -R "$BREW_TAP" >/dev/null 2>&1; then
    gh release upload "v$v" -R "$BREW_TAP" --clobber build/brew/*.tar.gz
  else
    gh release create "v$v" -R "$BREW_TAP" -t "uniai $v" -n "brew install $BREW_OWNER/uniai/uniai" build/brew/*.tar.gz >/dev/null
  fi
  echo "  published v$v: brew install $BREW_OWNER/uniai/uniai"
}

cmd_relay-pin() { need_box; ssh "$BOX" docker exec uniai-relay /relay pin; }

cmd_agent-install() {
  cmd_agent
  if [ ! -f "$HOME/.config/uniai/agent.json" ]; then # keep pairings on reinstall
    local pin; pin=$(cmd_relay-pin)
    bin/uniai init -relay "$RELAY_HOST:$RELAY_PORT" -pin "$pin"
  fi
  bin/uniai install
  mkdir -p "$HOME/.local/bin"
  ln -sf "$HOME/Library/Application Support/Uniai/uniai" "$HOME/.local/bin/uniai"
}

cmd_relay-deploy() {
  need_box
  quiet relay-build gorun linux amd64 go build -trimpath -ldflags=-s -o bin/relay-linux-amd64 ./cmd/relay
  ssh "$BOX" mkdir -p /opt/uniai
  scp -q bin/relay-linux-amd64 deploy/Dockerfile.relay deploy/compose.yml "$BOX":/opt/uniai/
  ssh "$BOX" 'cd /opt/uniai && docker compose up -d --build 2>&1 | tail -3 && sleep 2 && docker logs --tail 3 uniai-relay'
}

# The bz-uniai page (site/) + the release APK, served by nginx on the box's
# :8462 behind Cloudflare at https://$SITE. Placeholders come from the APK.
SITE=uniai.zarrinbal.org
SITE_PORT=8462
cmd_site-build() {
  local apk=app/build/app/outputs/flutter-apk/app-release.apk out=build/site
  [ -f "$apk" ] || cmd_apk
  rm -rf "$out" && mkdir -p "$out" && cp site/* "$out/" && cp "$apk" "$out/bz-uniai.apk"
  RELAY_HOST=$RELAY_HOST python3 - "$out/index.html" "$(sed -n 's/^version: *\([^+]*\).*/\1/p' app/pubspec.yaml)" \
    "$(awk '{printf "%.0f", $1/1048576}' <<<"$(stat -f%z "$apk")")" "$(shasum -a 256 "$apk" | cut -d' ' -f1)" <<'PY'
import os, sys
p, *v = sys.argv[1:]
t = open(p).read()
for k, x in zip(["@VERSION@", "@SIZE_MB@", "@SHA256@"], v):
    assert k in t and x, k
    t = t.replace(k, x)
host = os.environ.get("RELAY_HOST")
assert not (host and host in t) and "@" + "RELAY" not in t, "server address in the page"
open(p, "w").write(t)
PY
  echo "build/site: $(ls "$out" | tr '\n' ' ')"
}

cmd_site-deploy() { # never touches :443
  need_box
  cmd_site-build
  ssh "$BOX" 'mkdir -p /opt/uniai-site/www /opt/uniai-site/tls && cd /opt/uniai-site/tls && [ -f cert.pem ] ||
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=uniai" -keyout key.pem -out cert.pem 2>/dev/null; chmod 644 /opt/uniai-site/tls/*.pem'
  scp -q deploy/site/compose.yml deploy/site/nginx.conf "$BOX":/opt/uniai-site/
  rsync -az --delete build/site/ "$BOX":/opt/uniai-site/www/
  ssh "$BOX" "cd /opt/uniai-site && docker compose up -d 2>&1 | tail -1 && docker exec uniai-site nginx -s reload 2>/dev/null; sleep 1; curl -sk -o /dev/null -w 'origin :$SITE_PORT %{http_code}\n' https://127.0.0.1:$SITE_PORT/healthz"
  curl -s -o /dev/null -w "https://$SITE %{http_code}\n" "https://$SITE/" || true
}

# Once: the A record (proxied) and the Origin Rule sending https://$SITE to
# :$SITE_PORT, added next to the console's rule. Token from ~/.config/cloud/cf.env.
cmd_site-dns() {
  local tok zone=00436c43a4772a0789eda4900949f726 api=https://api.cloudflare.com/client/v4 rs
  tok=$(set +x; source ~/.config/cloud/cf.env; echo "${CLOUDFLARE_API_TOKEN:-${CF_API_TOKEN:-}}")
  cf() { curl -s -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' "$@"; }
  if [ "$(cf "$api/zones/$zone/dns_records?type=A&name=$SITE" | jq '.result|length')" = 0 ]; then
    cf -X POST "$api/zones/$zone/dns_records" --data "{\"type\":\"A\",\"name\":\"$SITE\",\"content\":\"${BOX#*@}\",\"proxied\":true,\"ttl\":1}" | jq -r '"dns: \(.success)"'
  else echo "dns: $SITE exists"; fi
  rs=$(cf "$api/zones/$zone/rulesets/phases/http_request_origin/entrypoint")
  if jq -e --arg h "$SITE" '.result.rules[]? | select(.expression | contains($h))' <<<"$rs" >/dev/null; then
    echo "origin rule: exists"
  else
    cf -X POST "$api/zones/$zone/rulesets/$(jq -r .result.id <<<"$rs")/rules" --data "{\"action\":\"route\",\"expression\":\"(http.host eq \\\"$SITE\\\")\",\"description\":\"uniai page -> :$SITE_PORT on the server\",\"action_parameters\":{\"origin\":{\"port\":$SITE_PORT}}}" |
      jq -r '"origin rule: \(.success) \(.errors|map(.message)|join(","))"'
  fi
}

cmd_vectors() { gorun linux arm64 go run ./cmd/noisevec > app/test/noise_vectors.json && echo "wrote app/test/noise_vectors.json"; }

cmd_app-test() { (cd app && quiet app-test flutter test "$@"); } # [file…]
cmd_icons() { scripts/icons.sh; } # app icon everywhere, from app/assets/icon/{background,foreground}.svg
cmd_app-pub() { (cd app && flutter pub "$@" 2>&1 | tail -n 15); } # add <pkg> | get | outdated
cmd_app-analyze() { (cd app && flutter analyze --no-pub 2>&1 | grep -E 'error|warning|info|issues found|No issues' | head -40); }

cmd_apk() {
  (cd app && quiet apk flutter build apk --release --target-platform android-arm64)
  ls -la app/build/app/outputs/flutter-apk/app-release.apk | awk '{print "app-release.apk", $5, "bytes"}'
}

MAC_APP=app/build/macos/Build/Products/Release/bz-uniai.app
# The app carries its core (Contents/MacOS/uniai) and installs it as this
# user's LaunchAgent when it finds none running. Adding a file breaks the
# bundle's signature, so it is signed again (ad hoc, entitlements kept).
cmd_mac-app() {
  cmd_agent >/dev/null || { echo "FAIL agent-build (log: $LOGS/agent-build.log)"; return 1; }
  (cd app && quiet mac-app flutter build macos --release) || return 1
  cp bin/uniai "$MAC_APP/Contents/MacOS/uniai"
  codesign -f -s - "$MAC_APP/Contents/MacOS/uniai" 2>/dev/null
  quiet mac-sign codesign -f -s - --preserve-metadata=entitlements,requirements,flags "$MAC_APP"
  du -sh "$MAC_APP" | awk '{print "bz-uniai.app", $1, "(core inside)"}'
}
cmd_mac-run() { cmd_mac-app; open "$MAC_APP"; }

cmd_install() {
  need_phone
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
  need_phone
  local code; code=$(bin/uniai pair -code)
  adb shell am start -a android.intent.action.VIEW -d "uniai://pair/$code" $APP_ID >/dev/null
  echo "pairing link sent to $ANDROID_SERIAL (valid 10 min); confirm on the phone"
}

cmd_log() { tail -n 40 "$HOME/Library/Logs/uniai.log"; }

cmd=${1:-help}; shift || true
if declare -f "cmd_$cmd" >/dev/null; then "cmd_$cmd" "$@"; else sed -n '2,/^set /p' "$0" | grep '^#'; fi
