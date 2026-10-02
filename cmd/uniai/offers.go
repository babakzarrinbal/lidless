package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"uniai/internal/config"
)

// Pairing back: a desktop that pairs with this Mac sends its own core's
// pairing code along ("back" in the hello). This Mac keeps the code until its
// own app takes it (devices.offers) and pairs with that desktop in turn, so
// each sees the other. docs/architecture.md, "Pairing".

var offersMu sync.Mutex

func offersPath() string { return filepath.Join(config.Dir(), "offers.json") }

// keepOffer saves a desktop's pairing code for this Mac's app. The code
// expires on its own Mac (10 minutes), so a stale one only fails to pair.
func (a *Agent) keepOffer(code string) {
	if !strings.HasPrefix(code, "mr1.") || len(code) > 2048 {
		return
	}
	offersMu.Lock()
	l := readOffers()
	if len(l) >= 8 {
		l = l[1:]
	}
	err := config.WriteJSON0600(offersPath(), append(l, code))
	offersMu.Unlock()
	if err != nil {
		logf("pair: can't keep the code to pair back: %v", err)
		return
	}
	a.devicesChanged() // this Mac's app asks for it
}

// takeOffers returns the kept codes and forgets them.
func takeOffers() []string {
	offersMu.Lock()
	defer offersMu.Unlock()
	l := readOffers()
	os.Remove(offersPath())
	return l
}

func readOffers() []string {
	l := []string{}
	if b, err := os.ReadFile(offersPath()); err == nil {
		json.Unmarshal(b, &l)
	}
	return l
}
