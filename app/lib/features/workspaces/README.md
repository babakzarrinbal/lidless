# workspaces

Folders on the Mac with their conversations, the Recent list, and starting a
new session.

Entry points: `WorkspaceList` (workspaces.dart), `RecentList`,
`NewSessionPage`, `SeenConversations`, `StatusDot`, `openTerms`,
`folderMenu` / `forgetRecentDir` (folder_menu.dart: long press or right
click a folder to take it off the recent folders).

RPC: `chat.sessions`, `chat.recent`, `fs.list`, `shell.list`; starts a
session through `term.open` (via terminals). Event: `terms`.

Tests: `test/features/workspaces/` (session_test, folder_menu_test).

Traps:
- The activity dot: green working, blinking blue unread, white read, gray
  closed. It follows `term.seen` offsets.
- Recent puts live terminals first; keep that order.
- Every long-press menu also opens on right click (`onSecondaryTap`), for
  the Mac app. A folder with open sessions can't be removed: they list it.
