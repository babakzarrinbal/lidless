# chat

Reading a Claude or Copilot conversation as chat, the agent pane that pairs
it with its terminal, and the Mac's usage cards.

Entry points: `ChatView`, `AgentPane`, `TranscriptPage`, `Chat` (chat.dart),
`Claude` (claude.dart), `ConversationTile`, `UsageCard`, `TokensCard`.

RPC: `chat.read`, `chat.older`, `chat.sessions`, `chat.recent`,
`chat.commands`, `chat.transcript` (VS Code Copilot Chat, only when the app
passes `vscode: true`), `chat.stop`, `chat.handoff`; `usage`, `tokens.reset`.

Tests: `test/features/chat/chat_test.dart`, `claude_test.dart`.

Traps:
- Transcripts are read from files on the Mac, so a chat can lag the terminal.
- `chat.transcript` and `chat.handoff` may be unknown on an older agent.
- Old messages load by offset (`chat.older`); keep scroll position stable.
