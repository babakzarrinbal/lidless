# internal/config

The agent's identity and settings on disk, under `~/.config/uniai/`:
`agent.json` (Noise keys, room and room key, relay and its pin, paired
devices, shared folders, default shell), `pairing.json` (the one-time token
`uniai pair` writes), and the folder other files live in (`terms/`,
`core.sock`, `agent.lock`).

Entry points: `Load` (`ErrNotSetUp` when there is no file), `Ensure` (makes a
local-only config if none), `New(relay, pin)`, `(*Config).Save`, `Key`,
`FindDevice`; `Dir`, `Path`, `PairingPath`; `WriteJSON0600`, `RandHex`.
Types: `Config`, `Device`, `Pairing`.

Test: `./dev.sh go test ./internal/config` (covered through `cmd/uniai`
tests too: `./dev.sh go test ./cmd/uniai`).

Traps: the file holds secrets (keys, room key): written 0600 through a temp
file and rename, never printed, never copied into pairing codes (`RoomKey`).
Treat a loaded `*Config` as read-only; copy, change, `Save`, and swap it in
(see `editDevices` in `cmd/uniai/devices.go`).
