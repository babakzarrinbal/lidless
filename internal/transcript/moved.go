package transcript

// A VS Code chat moved here ("Move here", vscode.go) carries on in a Copilot
// session that starts from a short prompt naming the chat's handoff file, not
// the whole chat. The chat view still shows the chat's history: a snapshot of
// its items (<id>.items.jsonl next to <id>.md, one ChatItem per line) comes
// first, then a "Disconnected from the original chat" line where the handoff
// prompt was, then the session.
//
// The phone pages by byte offsets (chat.read's next, chat.older's start). For
// a moved session they count the snapshot's bytes first, then events.jsonl's:
// offset p is the snapshot's p below its size n, else events.jsonl's p-n. The
// name the phone knows the transcript by carries n, so a new snapshot reads
// the chat over from the start.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// movedNote stands where the handoff prompt was.
const movedNote = "Disconnected from the original chat · carried on here"

// movedChat is where a moved session's history comes from.
type movedChat struct {
	snap string // the snapshot of the VS Code chat's items
	base int64  // its size: where the session's own offsets begin
}

// movedFrom is the snapshot that comes before a Copilot session's transcript,
// nil when the session was not moved from VS Code (or the chat is gone).
func movedFrom(events string) *movedChat {
	id := movedID(events)
	if id == "" {
		return nil
	}
	snap := filepath.Join(vscodeCache(), id+".items.jsonl")
	st, err := os.Stat(snap)
	if err != nil { // moved by an older agent: snapshot the chat now
		if writeSnapshot(id, snap) != nil {
			return nil
		}
		if st, err = os.Stat(snap); err != nil {
			return nil
		}
	}
	return &movedChat{snap: snap, base: st.Size()}
}

// name is the transcript's name for the phone, with the snapshot's size.
func (m *movedChat) name(name string) string {
	return fmt.Sprintf("%s+%d", name, m.base)
}

// movedIDs caches movedID per events.jsonl: its first message never changes.
var movedIDs sync.Map

// movedID is the VS Code chat a Copilot session carries on: the one its first
// message (the handoff prompt) names, "" for none.
func movedID(events string) string {
	if v, ok := movedIDs.Load(events); ok {
		return v.(string)
	}
	f, err := os.Open(events)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 8<<20)
	for n := 0; sc.Scan() && n < 200; n++ {
		l := sc.Bytes()
		if !bytes.Contains(l, []byte(`"user.message"`)) {
			continue
		}
		var e copilotEvent
		if json.Unmarshal(l, &e) != nil || e.Type != "user.message" || e.Data.Source != "" {
			continue
		}
		id := ""
		if m := reHandoff.FindStringSubmatch(e.Data.Content); m != nil {
			id = m[1]
		}
		movedIDs.Store(events, id)
		return id
	}
	return "" // no message yet: asked again next time
}

// writeSnapshot writes chat id's items as it is now to snap.
func writeSnapshot(id, snap string) error {
	path, _ := vscodeFind(id)
	if path == "" {
		return os.ErrNotExist
	}
	m, err := vscodeState(path)
	if err != nil {
		return err
	}
	return writeItems(snap, vscodeItems(m))
}

func writeItems(snap string, items []ChatItem) error {
	var b bytes.Buffer
	for _, it := range items {
		j, _ := json.Marshal(it)
		b.Write(append(j, '\n'))
	}
	if err := os.MkdirAll(filepath.Dir(snap), 0o700); err != nil {
		return err
	}
	tmp := snap + ".tmp"
	if err := os.WriteFile(tmp, b.Bytes(), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, snap)
}

// snapItems reads one snapshot line.
func snapItems(l []byte) []ChatItem {
	var it ChatItem
	if len(l) == 0 || json.Unmarshal(l, &it) != nil {
		return nil
	}
	return []ChatItem{it}
}

// older is the snapshot's page before offset before (at most its size).
func (m *movedChat) older(before int64) ([]ChatItem, int64, error) {
	f, err := os.Open(m.snap)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	return olderItems(f, min(before, m.base), snapItems)
}
