package transcript

// What the lists need from a VS Code chat — its title, the last thing typed
// and the model — without parsing it. Replaying a chat into its object
// (vscodeState) costs the file: this Mac has 1.5 GB of them and single chats
// over 100 MB, so doing that for every row hung the lists. Here the file is
// streamed and only these fields are matched, so a row costs the read alone.
//
// The edit log is not replayed, so the last match wins: a chat whose last
// requests were dropped (kind 2 with "i") and nothing typed since keeps the
// dropped prompt as its label until the next message. The row is a label;
// VSCodeHandoff still replays the chat in full.

import (
	"encoding/json"
	"io"
	"os"
	"regexp"
)

var (
	reVSPrompt    = regexp.MustCompile(`"message":\{"text":"((?:[^"\\]|\\.){0,300})`)
	reVSTitle     = regexp.MustCompile(`"customTitle":"((?:[^"\\]|\\.){0,300})"`)
	reVSTitleEdit = regexp.MustCompile(`"k":\["customTitle"\],"v":"((?:[^"\\]|\\.){0,300})"`)
	reVSModel     = regexp.MustCompile(`"modelId":"([^"]{0,100})"`)
)

// vscodeScanChunk is read at a time, vscodeScanKeep carried over to the next
// chunk so a match is never cut in half (the patterns are bounded well
// inside it).
const (
	vscodeScanChunk = 1 << 20
	vscodeScanKeep  = 4 << 10
)

// vscodeScan is a chat's title, the last prompt and the last model, from the
// file alone.
func vscodeScan(path string) (title, prompt, model string) {
	f, err := os.Open(path)
	if err != nil {
		return "", "", ""
	}
	defer f.Close()
	var first string // the first thing typed: the title of a chat VS Code never named
	buf := make([]byte, vscodeScanKeep+vscodeScanChunk)
	held := 0
	for {
		n, err := io.ReadFull(f, buf[held:])
		b := buf[:held+n]
		for _, m := range reVSPrompt.FindAllSubmatch(b, -1) {
			if s := vscodeUnquote(m[1]); s != "" {
				if first == "" {
					first = s
				}
				prompt = s
			}
		}
		for _, re := range []*regexp.Regexp{reVSTitle, reVSTitleEdit} {
			for _, m := range re.FindAllSubmatch(b, -1) {
				if s := vscodeUnquote(m[1]); s != "" {
					title = s
				}
			}
		}
		for _, m := range reVSModel.FindAllSubmatch(b, -1) {
			model = string(m[1])
		}
		if err != nil { // io.EOF or ErrUnexpectedEOF: that was the last chunk
			break
		}
		held = copy(buf, b[len(b)-vscodeScanKeep:])
	}
	return firstLine(title, first), firstLine(prompt), model
}

// vscodeUnquote reads a JSON string body back ("" when the bound cut an
// escape in half).
func vscodeUnquote(b []byte) string {
	var s string
	if json.Unmarshal(append(append([]byte{'"'}, b...), '"'), &s) != nil {
		return ""
	}
	return s
}
