# workspaces

Folders on the Mac with their conversations, the Recent list, and starting a
new session.

Entry points: `WorkspaceList` (workspaces.dart), `RecentList`,
`NewSessionPage`, `SeenConversations`, `StatusDot`, `openTerms`.

RPC: `chat.sessions`, `chat.recent`, `fs.list`, `shell.list`; starts a
session through `term.open` (via terminals). Event: `terms`.

Tests: `test/features/workspaces/session_test.dart`.

Traps:
- The activity dot: green working, blinking blue unread, white read, gray
  closed. It follows `term.seen` offsets.
- Recent puts live terminals first; keep that order.
