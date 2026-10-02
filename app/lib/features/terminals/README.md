# terminals

Shared terminals: the list per Mac, the live screen of each, the key bar and
the shell choice.

Entry points: `Terms` (terms.dart, the ChangeNotifier per Mac), `TermTab`
(term_tab.dart), `Session` and `Activity` (session.dart), `TermTabs`,
`TermSurface` (terminal_panel.dart), `TermSelect` (term_select.dart: mouse
drag, double/triple click, shift+click, a long press with handles on touch,
edge autoscroll, right-click menu, Cmd+C), with `select_range.dart` (the cell
math) and `select_handles.dart` (`Grab`, `SelHandle`), `term_menu.dart` (right-click menu,
`selectAll`), `ShellPanel`, `KeyBar`,
`ShellInfo`.

RPC: `term.list`, `term.open`, `term.attach`, `term.resize`, `term.seen`,
`term.rename`, `term.close`, `term.unpark` (old agents), `shell.list`,
`shell.set`. Events: `terms`, `term.exit`, `term.size`, `term.seen`.

Tests: `test/features/terminals/sync_test.dart`, `scroll_test.dart`,
`select_test.dart`.

Traps:
- terms.dart is about 650 lines: it is one class, and Dart cannot split a
  class without `part`, so it is left whole.
- A redraw after `term.size` is not news: it must not mark a terminal unread.
- An older agent answers `unknown`: handle the RpcError.
- xterm 4.0 detaches full-screen (alt buffer) lines when they scroll, and a
  selection on a detached line reads as none: `reattachLines` (term_tab.dart)
  repairs them after each write. select_test fails once xterm fixes it.
- `TermSelect` owns selection, not xterm: `Grab` wins every primary mouse
  pointer the moment it goes down, and its long press (400 ms) beats xterm's
  (500 ms). So a plain mouse click must forward to xterm by hand (focus, or a
  click to an app that asked for the mouse). Touch scrolling still wins when
  the finger moves before the long press.
- Holders outlive upgrades; the wire protocol must stay backward compatible.
