# Running Mac Remote: the official relay or your own

Mac Remote has three parts:

- the app on the phone;
- `macremote`, the agent on the Mac;
- a relay on a server.

The phone and the Mac both dial out to the relay, which joins the two sockets of
the same room. Everything between them is end-to-end encrypted (Noise_IK), so
the relay only ever forwards ciphertext. It holds no accounts and no keys, only
its TLS certificate and which agent claimed which room.

The app has no relay built in. The pairing code that `macremote pair` shows
carries the relay's address and its certificate pin. So the same app build
works against any relay: pairing tells it where to go.

## The official setup

This is how the author runs it.

- The relay runs in Docker on a small server, on its own port (8460). It uses
  `deploy/compose.yml` and `deploy/Dockerfile.relay`, deployed with
  `./dev.sh relay-deploy`.
- The Homebrew build of the agent has that relay and its pin compiled in, so
  there is nothing to configure.

On the Mac:

```sh
brew install babakzarrinbal/macremote/macremote
brew services start macremote
macremote pair        # shows a QR code
```

In the app, tap **Pair** (or **Pair another Mac** in the drawer) and scan the code. Each pairing code is
valid for 10 minutes and works once.

The tap is https://github.com/babakzarrinbal/homebrew-macremote.

## Your own relay

You need a server that can run Docker and has one TCP port open (8460 here).
The relay has no domain name or CA certificate. On first start it makes a
self-signed certificate, and the app and the agent both pin its sha256.

### 1. Build and start the relay

You can build without Go installed; the commands below run Go in Docker:

```sh
docker run --rm -v "$PWD":/src -w /src -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=amd64 \
  golang:1.26 go build -trimpath -ldflags=-s -o deploy/relay-linux-amd64 ./cmd/relay
cd deploy && docker compose up -d --build
docker exec macremote-relay /relay pin   # the certificate pin: 64 hex characters
```

For an arm64 server, set `GOARCH=arm64`. To use another port, change both
sides of `ports:` in `compose.yml` and the `-addr` in `Dockerfile.relay`.

The certificate is stored in the `data` volume, so the pin stays the same
across restarts and upgrades. If you delete the volume, you get a new pin and
every Mac must be pointed at the relay again (step 2).

### 2. Point the Mac at it

You can install the agent with brew, as above, or build it from this repo with
`./dev.sh agent-install`. Then:

```sh
macremote init -relay your.server:8460 -pin <pin>
brew services restart macremote     # or: macremote install
macremote pair
```

Running `init` on an agent that is already set up only changes the relay. Its
keys stay the same, but phones paired before the change still have the old
relay in their pairing. Pair them again.

To ship your own agent build with your relay compiled in, as the brew build
does, use:

```sh
go build -ldflags "-X main.defaultRelay=your.server:8460 -X main.defaultPin=<pin>" ./cmd/macremote
```

`./dev.sh brew` does this, along with the release tarballs and formula.

### 3. The app

Use the published app, or build it yourself with `./dev.sh apk`. Either one
works with your relay once it scans your Mac's pairing code.

## What the relay can and can't see

- **It sees:** room ids, the IP addresses that connect and how much traffic
  passes between them.
- **It can't see:** keystrokes, terminal output, files or Claude sessions. All
  of these are encrypted between the phone's key and the Mac's key.
- **Room claims:** the first agent to connect claims its room with its room
  key, and after that the relay refuses any other agent for that room. A relay
  operator can therefore deny service, but can't impersonate your Mac to your
  phone. The phone checks the Mac's static key from the pairing.
