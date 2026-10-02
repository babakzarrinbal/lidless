# chat

Reading a Claude or Copilot conversation as chat, the agent pane that pairs
it with its terminal, and the Mac's usage cards.

Entry points: `ChatView`, `AgentPane`, `Chat` (chat.dart),
`Claude` (claude.dart), `ConversationTile`, `UsageCard`, `TokensCard`.

RPC: `chat.read`, `chat.older`, `chat.sessions`, `chat.recent`,
`chat.commands` (the lists pass `vscode: true` for VS Code's chats);
`usage`, `tokens.reset`. Moving a conversation here (`chat.stop`,
`chat.handoff`) is `SessionFlows.resumeIn` in `lib/app/session_flows.dart`.

Tests: `test/features/chat/chat_test.dart`, `claude_test.dart`.

Traps:
- Transcripts are read from files on the Mac, so a chat can lag the terminal.
- `chat.handoff` may be unknown on an older agent; an older `chat.stop`
  quits only Claude.
- Old messages load by offset (`chat.older`); keep scroll position stable.
