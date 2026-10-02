// Package rpc holds what the core's RPC layers share. Today that is the error
// type that carries a machine-readable code to the app. Wire format and method
// list: cmd/uniai/wire.go, cmd/uniai/rpc.go and docs/architecture.md.
package rpc

// Error carries a machine-readable code to the app ("denied", "notfound", …).
// Plugins and the core return it; the session turns it into {"err","code"}.
type Error struct {
	Code string
	Msg  string
}

func (e *Error) Error() string { return e.Msg }
