# internal/rpc

Shared RPC types. Today: `rpc.Error{Code, Msg}`, the error an RPC method
returns when the app should see a code ("denied", "gone", "bad", "unknown"…).
`plugin.Error` is an alias of it, so there is one type.

Entry points: `rpc.Error`.

Test: `./dev.sh go build ./...` (a type only; the callers' tests cover it).

Traps: an app must cope with an older core, so never rename a code string;
only add new ones.
