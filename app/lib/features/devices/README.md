# devices

Pairing and managing devices: scan or enter a pairing code, list the paired
Macs, switch, rename or remove them, and (on a Mac, through its own core) the
devices paired to it, with a new pairing code (QR + text).

Entry points: `PairScreen`, `ScanPage` (pair.dart), `MacsPage` (macs.dart, the
Devices page), `PairedDevicesSection`, `PairCodeDialog` (devices.dart).
`devices_model.dart` is the `devices.*` RPC client (only the local link may ask;
core side: cmd/uniai/devices.go). Pairings are stored by `lib/net/store.dart`;
the connection is `lib/net/link.dart`.

Tests: `test/features/devices/macs_test.dart`.

Traps:
- Pairings live in `net/store.dart`; `devices_model.dart` is only the list of
  devices paired to this Mac's core.
- One phone key per Mac; removing a pairing must also drop its link.
- Never print or log keys, tokens or the relay address (public repo).
