package plugin

import (
	"encoding/json"
	"testing"
)

func panics(f func()) (p bool) {
	defer func() { p = recover() != nil }()
	f()
	return
}

func TestRegistry(t *testing.T) {
	ok := Plugin{Name: "b", Methods: []Method{{Name: "b.one", Params: json.RawMessage(`{}`), Write: true}}}
	r := New(ok, Plugin{Name: "a", Methods: []Method{{Name: "a.x"}}})
	if r.Lookup("b.one") == nil || r.Lookup("b.two") != nil {
		t.Fatal("lookup")
	}
	l := r.List()
	if len(l) != 2 || l[0].Name != "a" || !l[1].Methods[0].Write {
		t.Fatalf("list: %+v", l)
	}
	if !panics(func() { New(Plugin{Name: "b", Methods: []Method{{Name: "c.x"}}}) }) {
		t.Error("a method outside its namespace")
	}
	if !panics(func() { New(ok, ok) }) {
		t.Error("a duplicate method")
	}
	var v struct{ A int }
	if Decode(nil, &v) != nil || Decode(json.RawMessage(`null`), &v) != nil {
		t.Error("no params is an empty object")
	}
	if Decode(json.RawMessage(`{"A":"x"}`), &v) == nil {
		t.Error("bad params")
	}
}
