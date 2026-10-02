# alerts

Notifications when a terminal finishes work or asks something.

Entry points: `alerts.dart` (what counts as news, per terminal), `notify.dart`
(local notifications).

RPC and events: reads `terms` and terminal output through `Terms`; no RPC of
its own.

Tests: `test/features/alerts/activity_test.dart`.

Traps:
- Do not notify for the terminal on screen or for a redraw after `term.size`.
- Notify once per unread change (`TermTab.told`).
