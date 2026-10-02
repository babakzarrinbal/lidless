# workspaces

Folders on the Mac with their conversations, the Recent list, and starting a
new session.

Entry points: `WorkspaceList` (workspaces.dart), `RecentList`,
`NewSessionPage`, `SeenConversations`, `StatusDot`, `openTerms`,
`folderMenu` / `forgetRecentDir` (folder_menu.dart: long press or right
click a folder to take it off the recent folders), `Pins` / `pinMenu`
(pins.dart: long press or right click a session or conversation to pin it).

RPC: `chat.sessions`, `chat.recent`, `fs.list`, `shell.list`; starts a
session through `term.open` (via terminals). Event: `terms`.

Tests: `test/features/workspaces/` (session_test, folder_menu_test, pins_test).

Traps:
- The activity dot: green working, blinking blue unread, white read, gray
  closed. It follows `term.seen` offsets.
- Recent puts pinned conversations first, then live terminals; keep that
  order. The drawer shows pinned open sessions in a "Pinned" section above
  the folders (not again in their folder); pinned closed conversations come
  first in their folder.
- Pins are this device's only, per Mac (prefs `pinned:<mac>`), never sent to
  the Mac. A session pin (`s:`) goes when the session closes; its
  conversation's pin (`c:`, learned from the lists via `term`) lasts, and
  resuming it pins the new session (`SessionFlows.onResumed`).
- Every long-press menu also opens on right click (`onSecondaryTap`), for
  the Mac app. A folder with open sessions can't be removed: they list it.
