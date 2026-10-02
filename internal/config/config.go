// Package config owns the agent's identity and settings on disk:
// ~/.config/uniai/agent.json (keys, room, relay, paired devices, shared
// folders), the one-time pairing file, and the directory other files live in.
// Pairing and the protocol: docs/architecture.md.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/flynn/noise"
)

// Device is a phone allowed to connect, identified by its Noise static key.
type Device struct {
	Name  string    `json:"name"`
	Pub   string    `json:"pub"`
	Added time.Time `json:"added"`
}

type Config struct {
	Relay     string   `json:"relay"`   // host:port
	Pin       string   `json:"pin"`     // sha256 of the relay's certificate (hex)
	Room      string   `json:"room"`    // 32 random bytes (hex); the relay's meeting point
	RoomKey   string   `json:"roomKey"` // proves to the relay that this Mac owns Room (never in pairing codes)
	Priv      string   `json:"priv"`    // the Mac's Noise static key (hex)
	Pub       string   `json:"pub"`
	Devices   []Device `json:"devices"`
	Roots     []string `json:"roots"`           // folders the file browser may touch
	KeepAwake bool     `json:"keepAwake"`       // hold an idle-sleep assertion while running
	Shell     string   `json:"shell,omitempty"` // default shell for new terminals; empty: the login shell
}

// Pairing is a one-time token the next phone must present (written by `pair`).
type Pairing struct {
	Token   string    `json:"token"`
	Expires time.Time `json:"expires"`
}

func Dir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "uniai")
}

// SupportDir is where the agent binary and Claude's status files live.
func SupportDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Uniai")
}

func Path() string        { return filepath.Join(Dir(), "agent.json") }
func PairingPath() string { return filepath.Join(Dir(), "pairing.json") }

var ErrNotSetUp = errors.New("not set up: run `uniai setup host:port` (your relay)")

// Ensure loads the config, or makes one for this Mac alone: keys and a
// room, no relay until `uniai setup`, and no keep-awake.
func Ensure() (*Config, error) {
	c, err := Load()
	if err != ErrNotSetUp {
		return c, err
	}
	if c, err = New("", ""); err != nil {
		return nil, err
	}
	c.KeepAwake = false
	return c, c.Save()
}

// Load reads the config; ErrNotSetUp when there is none.
func Load() (*Config, error) {
	b, err := os.ReadFile(Path())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotSetUp
		}
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, err
	}
	return &c, nil
}

// WriteJSON0600 writes v atomically, readable by the owner only.
func WriteJSON0600(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (c *Config) Save() error { return WriteJSON0600(Path(), c) }

func (c *Config) Key() (noise.DHKey, error) {
	priv, err1 := hex.DecodeString(c.Priv)
	pub, err2 := hex.DecodeString(c.Pub)
	if err1 != nil || err2 != nil || len(priv) != 32 || len(pub) != 32 {
		return noise.DHKey{}, errors.New("bad key in config")
	}
	return noise.DHKey{Private: priv, Public: pub}, nil
}

func (c *Config) FindDevice(pub string) *Device {
	for i := range c.Devices {
		if c.Devices[i].Pub == pub {
			return &c.Devices[i]
		}
	}
	return nil
}

func RandHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func New(relay, pin string) (*Config, error) {
	k, err := noise.DH25519.GenerateKeypair(rand.Reader)
	if err != nil {
		return nil, err
	}
	home, _ := os.UserHomeDir()
	return &Config{
		Relay:     relay,
		Pin:       pin,
		Room:      RandHex(32),
		RoomKey:   RandHex(32),
		Priv:      hex.EncodeToString(k.Private),
		Pub:       hex.EncodeToString(k.Public),
		Roots:     []string{home},
		KeepAwake: true,
	}, nil
}
