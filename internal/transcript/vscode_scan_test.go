package transcript

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVSCodeScan(t *testing.T) {
	d := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(d, name)
		os.WriteFile(p, []byte(body), 0o644)
		return p
	}

	// The title VS Code set wins over the first prompt; the last prompt and
	// model are the chat's.
	p := write("a.jsonl", `{"kind":0,"v":{"customTitle":"Build fix","requests":[{"message":{"text":"fix the build"},"modelId":"gpt-5"}]}}
{"kind":2,"k":["requests"],"v":[{"message":{"text":"thanks\nand bye"},"modelId":"claude-opus-5.5"}]}
`)
	if title, prompt, model := vscodeScan(p); title != "Build fix" || prompt != "thanks" || model != "claude-opus-5.5" {
		t.Errorf("scan: %q %q %q", title, prompt, model)
	}

	// Unnamed: the first thing typed is the title. A later edit names it.
	p = write("b.jsonl", `{"kind":0,"v":{"customTitle":null,"requests":[{"message":{"text":"hello there"}}]}}
{"kind":2,"k":["requests"],"v":[{"message":{"text":"second"}}]}
`)
	if title, prompt, _ := vscodeScan(p); title != "hello there" || prompt != "second" {
		t.Errorf("unnamed: %q %q", title, prompt)
	}
	p = write("c.jsonl", `{"kind":0,"v":{"requests":[{"message":{"text":"hello"}}]}}
{"kind":1,"k":["customTitle"],"v":"Named later"}
`)
	if title, _, _ := vscodeScan(p); title != "Named later" {
		t.Errorf("renamed: %q", title)
	}

	// Escapes come back as text, and a quote inside a prompt ends nothing.
	p = write("d.jsonl", `{"kind":0,"v":{"requests":[{"message":{"text":"say \"hi\" to \\ me"}}]}}`+"\n")
	if _, prompt, _ := vscodeScan(p); prompt != `say "hi" to \ me` {
		t.Errorf("escapes: %q", prompt)
	}

	// Nothing said yet: no title, so the lists leave it out.
	p = write("e.jsonl", `{"kind":0,"v":{"customTitle":null,"requests":[]}}`+"\n")
	if title, prompt, _ := vscodeScan(p); title != "" || prompt != "" {
		t.Errorf("empty: %q %q", title, prompt)
	}
	if title, _, _ := vscodeScan(filepath.Join(d, "gone.jsonl")); title != "" {
		t.Errorf("missing file: %q", title)
	}

	// A match straddling the chunk bound is still found: padding puts the
	// last prompt just past the first chunk.
	pad := strings.Repeat("x", vscodeScanChunk-40)
	p = write("f.jsonl", fmt.Sprintf(`{"kind":0,"v":{"pad":%q,"requests":[{"message":{"text":"early"}}]}}`+"\n"+
		`{"kind":2,"k":["requests"],"v":[{"message":{"text":"late one"},"modelId":"gpt-5"}]}`+"\n", pad))
	if title, prompt, model := vscodeScan(p); title != "early" || prompt != "late one" || model != "gpt-5" {
		t.Errorf("across chunks: %q %q %q", title, prompt, model)
	}
}
