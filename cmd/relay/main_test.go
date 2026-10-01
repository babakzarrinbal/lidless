package main

import (
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestOwnsClaimsFirstKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claims.json")
	h := &hub{claims: loadClaims(path), claimsPath: path}
	room := strings.Repeat("a", 64)
	req := func(key string) bool {
		r := httptest.NewRequest("GET", "/v1/agent?room="+room, nil)
		if key != "" {
			r.Header.Set("Authorization", "Bearer "+key)
		}
		return h.owns(room, r)
	}
	k1, k2 := strings.Repeat("1", 64), strings.Repeat("2", 64)
	if req("") || req("short") {
		t.Fatal("accepted a missing or malformed key")
	}
	if !req(k1) || !req(k1) {
		t.Fatal("first key should claim and keep the room")
	}
	if req(k2) {
		t.Fatal("second key took over a claimed room")
	}
	// The claim survives a restart.
	h2 := &hub{claims: loadClaims(path), claimsPath: path}
	h = h2
	if req(k2) || !req(k1) {
		t.Fatal("claim not persisted")
	}
}
