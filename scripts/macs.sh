#!/usr/bin/env bash
# Installs the Mac app (build/bz-uniai-mac.zip) on this Mac and on your other
# Macs over ssh, the way ./dev.sh install puts the APK on a phone.
#
# Once, on the other Mac (System Settings → General → Sharing → Remote Login
# on), let this Mac in: it takes only the key whose fingerprint you give, from
# the keys your GitHub account publishes.
#   ./dev.sh mac-allow <SHA256:fingerprint>     prints the line for mac-add
# Then here:
#   ./dev.sh mac-add <user@host.local>          remembered in .macs (untracked)
#   ./dev.sh mac-install [here|all|<user@host>] build the zip, install, open (default: all)
#   ./dev.sh mac-fp                             this Mac's key fingerprint, for mac-allow
#
# The app installs or updates its core (the LaunchAgent) itself at start, so
# copying the app is the whole update. Terminals live in holders and survive.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP=build/bz-uniai-mac.zip
MACS=.macs
OWNER=${BREW_OWNER:-babakzarrinbal}
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8)

# The steps on the target Mac; the zip is at ~/Downloads/bz-uniai-mac.zip.
# Unzipped outside /Applications first: ditto can't extract into it.
STEPS='set -e
pkill -x bz-uniai 2>/dev/null && sleep 1 || true
rm -rf ~/Downloads/bz-uniai-new
ditto -x -k ~/Downloads/bz-uniai-mac.zip ~/Downloads/bz-uniai-new
rm -rf /Applications/bz-uniai.app
mv ~/Downloads/bz-uniai-new/bz-uniai.app /Applications/
rm -rf ~/Downloads/bz-uniai-new
xattr -dr com.apple.quarantine /Applications/bz-uniai.app 2>/dev/null || true
open /Applications/bz-uniai.app
sleep 5
pgrep -xq bz-uniai || { echo "the app did not start"; exit 1; }
echo "app $(defaults read /Applications/bz-uniai.app/Contents/Info CFBundleShortVersionString) running; $(~/.local/bin/uniai status 2>&1 | grep -E "^(agent|phones)" | tr -s " " | paste -sd, -)"'

fp() { ssh-keygen -lf ~/.ssh/id_ed25519.pub | awk '{print $2}'; }

allow() {
  local want=${1:?usage: mac-allow <SHA256:fingerprint> (./dev.sh mac-fp on the Mac that connects)}
  local key="" k
  while read -r k; do
    [ -n "$k" ] || continue
    [ "$(echo "$k" | ssh-keygen -lf - | awk '{print $2}')" = "$want" ] && key=$k
  done < <(curl -fsS "https://github.com/$OWNER.keys")
  [ -n "$key" ] || { echo "FAIL mac-allow: no key $want on github.com/$OWNER.keys" >&2; exit 1; }
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
  grep -qF "$key" ~/.ssh/authorized_keys || echo "$key" >> ~/.ssh/authorized_keys
  nc -z -G 2 localhost 22 2>/dev/null ||
    echo "Remote Login is off: System Settings → General → Sharing → Remote Login"
  echo "PASS mac-allow. On the other Mac run:"
  echo "./dev.sh mac-add $(whoami)@$(scutil --get LocalHostName).local"
}

add() {
  local to=${1:?usage: mac-add <user@host.local>}
  "${SSH[@]}" "$to" true || { echo "FAIL mac-add: ssh $to (run ./dev.sh mac-allow \$(./dev.sh mac-fp) there)" >&2; exit 1; }
  touch "$MACS"
  grep -qxF "$to" "$MACS" || echo "$to" >> "$MACS"
  echo "PASS mac-add $to"
}

one() { # one <here|user@host>
  if [ "$1" = here ]; then
    [ "$(realpath "$ZIP")" = "$(realpath ~/Downloads/bz-uniai-mac.zip 2>/dev/null)" ] || cp "$ZIP" ~/Downloads/bz-uniai-mac.zip
    bash -c "$STEPS"
  else
    scp -q -o BatchMode=yes -o ConnectTimeout=8 "$ZIP" "$1:Downloads/bz-uniai-mac.zip"
    "${SSH[@]}" "$1" "bash -c $(printf %q "$STEPS")"
  fi
}

install() {
  local which=${1:-all} t targets=() fails=0
  case $which in
    here) targets=(here) ;;
    all) targets=(here); [ -f "$MACS" ] && while read -r t; do [ -n "$t" ] && targets+=("$t"); done < "$MACS" ;;
    *) targets=("$which") ;;
  esac
  ./dev.sh mac-zip | tail -1
  for t in "${targets[@]}"; do
    if out=$(one "$t" 2>&1); then
      echo "PASS mac-install $t: $(echo "$out" | tail -1)"
    else
      echo "FAIL mac-install $t: $(echo "$out" | tail -2 | tr '\n' ' ')"
      fails=1
    fi
  done
  return $fails
}

cmd=${1:-}; shift || true
case $cmd in
  allow) allow "$@" ;;
  add) add "$@" ;;
  install) install "$@" ;;
  fp) fp ;;
  *) sed -n '2,/^set /p' "$0" | grep '^#'; exit 1 ;;
esac
