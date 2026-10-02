package main

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

func configDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "uniai")
}

func configPath() string  { return filepath.Join(configDir(), "agent.json") }
func pairingPath() string { return filepath.Join(configDir(), "pairing.json") }

var errNotSetUp = errors.New("not set up: run `uniai setup host:port` (your relay)")

// ensureConfig loads the config, or makes one for this Mac alone: keys and a
// room, no relay until `uniai setup`, and no keep-awake.
func ensureConfig() (*Config, error) {
	c, err := loadConfig()
	if err != errNotSetUp {
		return c, err
	}
	if c, err = newConfig("", ""); err != nil {
		return nil, err
	}
	c.KeepAwake = false
	return c, c.save()
}

func loadConfig() (*Config, error) {
	b, err := os.ReadFile(configPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, errNotSetUp
		}
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, err
	}
	return &c, nil
}

// writeJSON0600 writes v atomically, readable by the owner only.
func writeJSON0600(path string, v any) error {
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

func (c *Config) save() error { return writeJSON0600(configPath(), c) }

func (c *Config) key() (noise.DHKey, error) {
	priv, err1 := hex.DecodeString(c.Priv)
	pub, err2 := hex.DecodeString(c.Pub)
	if err1 != nil || err2 != nil || len(priv) != 32 || len(pub) != 32 {
		return noise.DHKey{}, errors.New("bad key in config")
	}
	return noise.DHKey{Private: priv, Public: pub}, nil
}

func (c *Config) device(pub string) *Device {
	for i := range c.Devices {
		if c.Devices[i].Pub == pub {
			return &c.Devices[i]
		}
	}
	return nil
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func newConfig(relay, pin string) (*Config, error) {
	k, err := noise.DH25519.GenerateKeypair(rand.Reader)
	if err != nil {
		return nil, err
	}
	home, _ := os.UserHomeDir()
	return &Config{
		Relay:     relay,
		Pin:       pin,
		Room:      randHex(32),
		RoomKey:   randHex(32),
		Priv:      hex.EncodeToString(k.Private),
		Pub:       hex.EncodeToString(k.Public),
		Roots:     []string{home},
		KeepAwake: true,
	}, nil
}
