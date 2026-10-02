package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"

	"uniai/internal/config"
)

// Devices paired with this Mac, managed from this Mac's own app: a new
// pairing code, the list, rename, remove. Only the local session may ask
// (session.go); a phone cannot add or drop other phones.

type pairCode struct {
	Relay string `json:"r"`
	Pin   string `json:"p"`
	Room  string `json:"m"`
	Key   string `json:"k"`
	Token string `json:"t"`
	Host  string `json:"n"`
}

const pairFor = 10 * time.Minute

// newPairCode writes a one-time token the next phone must present and
// returns the code that carries it. A new code replaces the last one.
func newPairCode(c *config.Config) (string, config.Pairing, error) {
	if c.Relay == "" {
		return "", config.Pairing{}, config.ErrNotSetUp
	}
	p := config.Pairing{Token: config.RandHex(16), Expires: time.Now().Add(pairFor)}
	if err := config.WriteJSON0600(config.PairingPath(), p); err != nil {
		return "", p, err
	}
	b, _ := json.Marshal(pairCode{c.Relay, c.Pin, c.Room, c.Pub, p.Token, computerName()})
	return "mr1." + base64.RawURLEncoding.EncodeToString(b), p, nil
}

type deviceInfo struct {
	Name   string    `json:"name"`
	Pub    string    `json:"pub"`
	Added  time.Time `json:"added"`
	Online bool      `json:"online"`
}

func (a *Agent) devices() []deviceInfo {
	a.reload()
	c := a.config()
	a.mu.Lock()
	on := map[string]bool{}
	for s := range a.sessions {
		if !s.local {
			on[s.pub] = true
		}
	}
	a.mu.Unlock()
	res := make([]deviceInfo, 0, len(c.Devices))
	for _, d := range c.Devices {
		res = append(res, deviceInfo{d.Name, d.Pub, d.Added, on[d.Pub]})
	}
	return res
}

// editDevices changes the device list in agent.json; reload then drops the
// sessions of a removed phone. Everyone hears {"ev":"devices"}.
func (a *Agent) editDevices(pub string, edit func([]config.Device, int) []config.Device) error {
	a.reload() // don't write back a stale copy
	a.mu.Lock()
	nc := *a.cfg
	i := -1
	for j, d := range nc.Devices {
		if d.Pub == pub {
			i = j
		}
	}
	if i < 0 {
		a.mu.Unlock()
		return &rpcError{Code: "gone", Msg: "that device is no longer paired"}
	}
	nc.Devices = edit(append([]config.Device(nil), nc.Devices...), i)
	a.mu.Unlock()
	if err := nc.Save(); err != nil {
		return err
	}
	a.reload()
	a.devicesChanged()
	return nil
}

func (a *Agent) renameDevice(pub, name string) error {
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 60 {
		return &rpcError{Code: "bad", Msg: "a name is 1 to 60 characters"}
	}
	return a.editDevices(pub, func(ds []config.Device, i int) []config.Device {
		ds[i].Name = name
		return ds
	})
}

func (a *Agent) removeDevice(pub string) error {
	return a.editDevices(pub, func(ds []config.Device, i int) []config.Device { return append(ds[:i], ds[i+1:]...) })
}

func (a *Agent) devicesChanged() { a.broadcast(map[string]any{"ev": "devices"}) }

func (a *Agent) deviceCall(method, pub, name string) (any, error) {
	switch method {
	case "devices.pair":
		code, p, err := newPairCode(a.config())
		if err == config.ErrNotSetUp {
			return nil, &rpcError{Code: "setup", Msg: "this Mac has no relay yet: run `uniai setup host:port` once"}
		} else if err != nil {
			return nil, err
		}
		logf("this Mac's app made a pairing code")
		return map[string]any{"code": code, "expires": p.Expires, "host": computerName()}, nil
	case "devices.rename":
		if err := a.renameDevice(pub, name); err != nil {
			return nil, err
		}
	case "devices.remove":
		if err := a.removeDevice(pub); err != nil {
			return nil, err
		}
		logf("this Mac's app removed a phone (%.12s…)", pub)
	}
	return a.devices(), nil
}
