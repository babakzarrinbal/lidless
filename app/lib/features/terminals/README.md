# terminals

Shared terminals: the list per Mac, the live screen of each, the key bar and
the shell choice.

Entry points: `Terms` (terms.dart, the ChangeNotifier per Mac), `TermTab`
(term_tab.dart), `Session` and `Activity` (session.dart), `TermTabs`,
`TermSurface` (terminal_panel.dart), `ShellPanel`, `KeyBar`, `ShellInfo`.

RPC: `term.list`, `term.open`, `term.attach`, `term.resize`, `term.seen`,
`term.rename`, `term.close`, `term.unpark` (old agents), `shell.list`,
`shell.set`. Events: `terms`, `term.exit`, `term.size`, `term.seen`.

Tests: `test/features/terminals/sync_test.dart`, `scroll_test.dart`.

Traps:
- terms.dart is about 650 lines: it is one class, and Dart cannot split a
  class without `part`, so it is left whole.
- A redraw after `term.size` is not news: it must not mark a terminal unread.
- An older agent answers `unknown`: handle the RpcError.
- Holders outlive upgrades; the wire protocol must stay backward compatible.
