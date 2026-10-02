# Running bz-uniai: the official relay or your own

bz-uniai has three parts:

- the app on the phone;
- `uniai`, the agent on the Mac;
- a relay on a server.

The phone and the Mac both dial out to the relay, which joins the two sockets of
the same room. Everything between them is end-to-end encrypted (Noise_IK), so
the relay only ever forwards ciphertext. It holds no accounts and no keys, only
its TLS certificate and which agent claimed which room.

The app has no relay built in. The pairing code that `uniai pair` shows
carries the relay's address and its certificate pin. So the same app build
works against any relay: pairing tells it where to go.

## Setting it up

1. **A relay.** Run it on any server that has Docker (below), and note its
   certificate pin.
2. **The Mac.** Install the agent and point it at that relay:

   ```sh
   brew install babakzarrinbal/uniai/uniai
   uniai setup your.server:8460
   ```

   `setup` shows the relay's certificate pin. Check that it matches
   `docker exec uniai-relay /relay pin` on the server, or pass the pin with
   `-pin <sha256>` to skip the question. It then starts the agent as a brew
   service (now and at every login) and shows a pairing QR code.
3. **The phone.** In the app, tap **Pair** (or **Pair another Mac** in the
   drawer) and scan the code. Each pairing code is valid for 10 minutes and
   works once. To pair more phones later, run `uniai pair`.

The brew package is generic: no relay is built in. Every Mac names its own
relay with `setup`. The tap is
https://github.com/babakzarrinbal/homebrew-uniai.

To point a Mac that is already set up at another relay, run `setup` again. Its
keys stay the same, but phones paired before the change still have the old
relay in their pairing, so pair them again.

## Running a relay

You need a server that can run Docker and has one TCP port open (8460 here).
The relay needs no domain name and no CA certificate. On first start it makes
a self-signed certificate, and the app and the agent both pin its sha256.

You can build without Go installed; the commands below run Go in Docker:

```sh
docker run --rm -v "$PWD":/src -w /src -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=amd64 \
  golang:1.26 go build -trimpath -ldflags=-s -o deploy/relay-linux-amd64 ./cmd/relay
cd deploy && docker compose up -d --build
docker exec uniai-relay /relay pin   # the certificate pin: 64 hex characters
```

The relay's log at startup also shows the `uniai setup` line to run on a
Mac.

- **arm64 server:** set `GOARCH=arm64`.
- **Another port:** change both sides of `ports:` in `compose.yml`, and the
  `-addr` in `Dockerfile.relay`.

The certificate is stored in the `data` volume, so the pin stays the same
across restarts and upgrades. If you delete the volume, the pin changes, and
every Mac needs `uniai setup` again.

The author's relay runs this way on port 8460 and is deployed with
`./dev.sh relay-deploy`.

## Building it yourself

- **Agent:** `./dev.sh agent-install` builds it, installs it as a LaunchAgent
  instead of a brew service, and links `~/.local/bin/uniai`. A Mac that
  isn't set up yet gets the author's relay; to use another one, run
  `uniai setup host:port`.
- **App:** use the published app, or build it with `./dev.sh apk`. Any build
  works with any relay once it scans a pairing code.

## What the relay can and can't see

- **It sees:** room ids, the IP addresses that connect and how much traffic
  passes between them.
- **It can't see:** keystrokes, terminal output, files or Claude sessions. All
  of these are encrypted between the phone's key and the Mac's key.
- **Room claims:** the first agent to connect claims its room with its room
  key, and after that the relay refuses any other agent for that room. A relay
  operator can therefore deny service, but can't impersonate your Mac to your
  phone. The phone checks the Mac's static key from the pairing.
