// Command noisevec writes Noise IK test vectors (fixed keys) that the
// phone's Dart implementation must reproduce byte for byte.
//
//	go run ./cmd/noisevec > app/test/noise_vectors.json
package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"

	"github.com/flynn/noise"
)

func key(seed byte) noise.DHKey {
	k, err := noise.DH25519.GenerateKeypair(bytes.NewReader(bytes.Repeat([]byte{seed}, 32)))
	if err != nil {
		panic(err)
	}
	return k
}

func main() {
	suite := noise.NewCipherSuite(noise.DH25519, noise.CipherChaChaPoly, noise.HashSHA256)
	is, ie, rs, re := key(1), key(2), key(3), key(4)
	// The "e" token always draws a fresh keypair from Random, so the seeds go there.
	seed := func(b byte) *bytes.Reader { return bytes.NewReader(bytes.Repeat([]byte{b}, 32)) }
	ini, _ := noise.NewHandshakeState(noise.Config{CipherSuite: suite, Random: seed(2), Pattern: noise.HandshakeIK, Initiator: true, Prologue: []byte("uniai/1"), StaticKeypair: is, PeerStatic: rs.Public})
	res, _ := noise.NewHandshakeState(noise.Config{CipherSuite: suite, Random: seed(4), Pattern: noise.HandshakeIK, Prologue: []byte("uniai/1"), StaticKeypair: rs})

	p1 := []byte(`{"v":1,"name":"test"}`)
	m1, _, _, err := ini.WriteMessage(nil, p1)
	must(err)
	_, _, _, err = res.ReadMessage(nil, m1)
	must(err)
	p2 := []byte(`{"v":1,"host":"mac"}`)
	m2, rIn, rOut, err := res.WriteMessage(nil, p2)
	must(err)
	_, iOut, iIn, err := ini.ReadMessage(nil, m2)
	must(err)
	_ = iIn
	_ = rIn

	t1, _ := iOut.Encrypt(nil, nil, []byte("phone to mac 1"))
	t2, _ := iOut.Encrypt(nil, nil, []byte("phone to mac 2"))
	t3, _ := rOut.Encrypt(nil, nil, []byte("mac to phone 1"))

	h := hex.EncodeToString
	json.NewEncoder(os.Stdout).Encode(map[string]string{
		"is_priv": h(is.Private), "is_pub": h(is.Public),
		"ie_priv": h(ie.Private), "ie_pub": h(ie.Public),
		"rs_priv": h(rs.Private), "rs_pub": h(rs.Public),
		"re_priv": h(re.Private), "re_pub": h(re.Public),
		"p1": string(p1), "m1": h(m1),
		"p2": string(p2), "m2": h(m2),
		"t1": h(t1), "t2": h(t2), "t3": h(t3),
	})
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
