package main

import (
	"reflect"
	"testing"

	"uniai/internal/config"
)

// A desktop pairing for the first time leaves its code for this Mac's app;
// a known device reconnecting, or junk, leaves nothing.
func TestPairBackOffer(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	c, err := config.Ensure()
	if err != nil {
		t.Fatal(err)
	}
	c.Relay = "relay.test:8460"
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	a := &Agent{cfg: c, host: "test-mac", terms: newTerms(), plugins: corePlugins(), sessions: map[*Session]struct{}{}}
	_, p, err := newPairCode(c)
	if err != nil {
		t.Fatal(err)
	}
	pub := "ab" + c.Pub[2:]
	if _, err := a.authorize(pub, hello{Name: "other-mac", Pair: p.Token, Back: "mr1.back"}); err != nil {
		t.Fatal(err)
	}
	if got := takeOffers(); !reflect.DeepEqual(got, []string{"mr1.back"}) {
		t.Fatalf("offers after pairing: %v", got)
	}
	if got := takeOffers(); len(got) != 0 {
		t.Fatalf("offers are taken once: %v", got)
	}
	if _, err := a.authorize(pub, hello{Name: "other-mac", Back: "mr1.again"}); err != nil {
		t.Fatal(err)
	}
	a.keepOffer("not a code")
	if got := takeOffers(); len(got) != 0 {
		t.Fatalf("no offer from a known device or junk: %v", got)
	}
}
