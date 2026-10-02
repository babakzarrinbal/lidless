// One session on screen: its terminal, chat and files panels and the switch between them.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/features/files/files.dart';
import 'package:uniai/features/terminals/shell_panel.dart';
import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/chat/claude.dart';
import 'package:uniai/features/terminals/terms.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/features/chat/agent_pane.dart';
import 'package:uniai/features/files/files_panel.dart';
import 'package:uniai/features/workspaces/new_session.dart';
import 'package:uniai/features/terminals/shells.dart';
import 'package:uniai/features/terminals/terminal_panel.dart';
import 'package:uniai/app/theme.dart';

enum Pane { agent, shell, files }

/// One session on screen: the agent (Claude, Copilot or a shell) on top, then
/// a collapsible shell pane and a collapsible files pane. Drag a pane's
/// header to resize it; tap its title to collapse or expand it. While the
/// keyboard is up only the focused pane shows.
class SessionView extends StatefulWidget {
  const SessionView({
    super.key,
    required this.terms,
    required this.session,
    required this.files,
    required this.fontSize,
    required this.keyboard,
    required this.onRestart,
    required this.onConversation,
  });
  final Terms terms;
  final Session session;
  final Files files;
  final double fontSize;
  final bool keyboard;
  final VoidCallback onRestart;
  final ValueChanged<Conversation> onConversation;

  @override
  State<SessionView> createState() => SessionViewState();
}

class SessionViewState extends State<SessionView> {
  final _shellKey = GlobalKey<ShellPanelState>();
  // Pane body heights as fractions of the space below the agent's minimum.
  double _shellH = .3, _filesH = .3;
  bool _shellOpen = false, _filesOpen = false;
  Pane _focus = Pane.agent;
  SharedPreferences? _prefs;
  double _avail = 1; // last laid-out space for pane bodies, in pixels

  static const _hh = 40.0, _minAgent = 150.0, _minBody = 70.0;

  Terms get terms => widget.terms;
  Session get session => widget.session;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _prefs = p;
        _shellOpen = p.getBool('shellOpen') ?? false;
        _filesOpen = p.getBool('filesOpen') ?? false;
        _shellH = p.getDouble('shellH') ?? .3;
        _filesH = p.getDouble('filesH') ?? .3;
      });
    });
  }

  void _save() {
    final p = _prefs;
    if (p == null) return;
    p.setBool('shellOpen', _shellOpen);
    p.setBool('filesOpen', _filesOpen);
    p.setDouble('shellH', _shellH);
    p.setDouble('filesH', _filesH);
  }

  void _focused(Pane p) {
    if (_focus != p) setState(() => _focus = p);
  }

  Future<TermTab?> _newShell({String? shell}) async {
    try {
      return await terms.open(
        session: session.id,
        dir: session.dir,
        sizeLike: terms.activeShell(session),
        shell: shell,
      );
    } on RpcError catch (e) {
      if (mounted) toast(context, e.message, error: true);
      return null;
    }
  }

  Future<void> _pickShell() async {
    final shell = await pickShell(context, terms, title: 'New shell with');
    if (shell != null && mounted) _newShell(shell: shell);
  }

  void _toggle(Pane p) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      if (p == Pane.shell) {
        _shellOpen = !_shellOpen;
        if (_shellOpen && session.shells.where((t) => !t.exited).isEmpty) _newShell();
      } else {
        _filesOpen = !_filesOpen;
      }
    });
    _save();
  }

  /// Opens the shell pane and types [cmd] into a live shell ([newTab]: a new
  /// one). [paste] pastes it instead, so nothing runs until Enter.
  Future<void> runInShell(String cmd, {bool newTab = false, bool keyboard = true, bool paste = false}) async {
    setState(() {
      _shellOpen = true;
      _focus = Pane.shell;
    });
    _save();
    var t = terms.activeShell(session);
    if (newTab || t == null || t.exited) t = await _newShell();
    if (t == null) return;
    terms.selectShell(session, t);
    if (paste) {
      terms.paste(t, cmd);
    } else {
      terms.type(t, cmd);
    }
    if (keyboard) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _shellKey.currentState?.showKeyboard());
    }
  }

  // Dragging a header: up grows its pane, down shrinks it. A collapsed pane
  // opens when dragged up; one dragged below the minimum collapses.
  double? _dragPx;
  void _dragStart(Pane p) {
    final open = p == Pane.shell ? _shellOpen : _filesOpen;
    _dragPx = open ? (p == Pane.shell ? _shellH : _filesH) * _avail : 0;
  }

  void _dragUpdate(Pane p, double dy) {
    final px = _dragPx;
    if (px == null) return;
    final other = p == Pane.shell ? (_filesOpen ? _filesH * _avail : 0) : (_shellOpen ? _shellH * _avail : 0);
    final next = (px - dy).clamp(0.0, (_avail - other).clamp(0.0, _avail));
    _dragPx = next;
    setState(() {
      final f = (next / _avail).clamp(0.0, 1.0);
      if (p == Pane.shell) {
        if (!_shellOpen && next > 8) {
          _shellOpen = true;
          if (session.shells.where((t) => !t.exited).isEmpty) _newShell();
        }
        if (_shellOpen) _shellH = f;
      } else {
        if (!_filesOpen && next > 8) _filesOpen = true;
        if (_filesOpen) _filesH = f;
      }
    });
  }

  void _dragEnd(Pane p) {
    // A tap also ends in a drag cancel; only a real drag may collapse.
    final px = _dragPx;
    if (px == null) return;
    _dragPx = null;
    setState(() {
      if (px < _minBody) {
        if (p == Pane.shell) {
          _shellOpen = false;
          _shellH = .3;
        } else {
          _filesOpen = false;
          _filesH = .3;
        }
      }
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) => _layout(c.biggest));
  }

  Widget _layout(Size size) {
    final W = size.width, H = size.height;
    final avail = (H - 2 * _hh - _minAgent).clamp(0.0, double.infinity);
    _avail = avail <= 0 ? 1 : avail;
    var s = _shellOpen ? _shellH * avail : 0.0;
    var f = _filesOpen ? _filesH * avail : 0.0;
    if (s + f > avail) {
      final k = avail / (s + f);
      s *= k;
      f *= k;
    }
    final a = H - 2 * _hh - s - f;

    var ab = Rect.fromLTWH(0, 0, W, a);
    var sh = Rect.fromLTWH(0, a, W, _hh);
    var sb = Rect.fromLTWH(0, a + _hh, W, s);
    var fh = Rect.fromLTWH(0, a + _hh + s, W, _hh);
    var fb = Rect.fromLTWH(0, a + 2 * _hh + s, W, f);
    var showA = true, showSH = true, showFH = true, showSB = _shellOpen, showFB = _filesOpen;

    if (widget.keyboard) {
      // Only the pane being typed into.
      switch (_focus) {
        case Pane.agent:
          showSH = showSB = showFH = showFB = false;
          ab = Rect.fromLTWH(0, 0, W, H);
        case Pane.shell:
          showA = showFH = showFB = false;
          showSB = true;
          sh = Rect.fromLTWH(0, 0, W, _hh);
          sb = Rect.fromLTWH(0, _hh, W, H - _hh);
        case Pane.files:
          showA = showSH = showSB = false;
          showFB = true;
          fh = Rect.fromLTWH(0, 0, W, _hh);
          fb = Rect.fromLTWH(0, _hh, W, H - _hh);
      }
    }

    Widget place(Rect r, bool show, Widget child) => Positioned.fromRect(
          // A hidden body keeps a sane size so terminals don't shrink to 0.
          rect: show || r.height >= _minBody ? r : Rect.fromLTWH(r.left, r.top, r.width, _minBody * 2),
          child: Offstage(offstage: !show, child: TickerMode(enabled: show, child: child)),
        );

    return Stack(children: [
      place(ab, showA, Container(
        color: C.bg,
        child: AgentPane(
          terms: terms,
          session: session,
          fontSize: widget.fontSize,
          onFocus: () => _focused(Pane.agent),
          onRestart: widget.onRestart,
          onConversation: widget.onConversation,
          onToShell: (code) => runInShell(code, paste: true, keyboard: false),
        ),
      )),
      place(sb, showSB, Container(
        color: C.bg,
        child: ShellPanel(
          key: _shellKey,
          terms: terms,
          session: session,
          fontSize: widget.fontSize,
          onFocus: () => _focused(Pane.shell),
        ),
      )),
      place(fb, showFB, Container(
        color: C.bg,
        child: FilesPanel(
          files: widget.files,
          fontSize: widget.fontSize,
          onFocus: () => _focused(Pane.files),
          onCdInTerminal: (dir) => runInShell('cd ${shellQuote(dir)}\r'),
        ),
      )),
      place(sh, showSH, _header(Pane.shell)),
      place(fh, showFH, _header(Pane.files)),
    ]);
  }

  Widget _header(Pane p) {
    final shell = p == Pane.shell;
    final open = shell ? _shellOpen : _filesOpen;
    final title = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(shell ? Icons.terminal_rounded : Icons.folder_open_rounded,
          size: 18, color: shell ? C.green : C.amber),
      const SizedBox(width: 8),
      if (!open)
        Text(shell ? 'Shell' : 'Files', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
    ]);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _dragStart(p),
      onVerticalDragUpdate: (d) => _dragUpdate(p, d.delta.dy),
      onVerticalDragEnd: (_) => _dragEnd(p),
      onVerticalDragCancel: () => _dragEnd(p),
      child: Material(
        color: C.panel,
        child: InkWell(
          onTap: open ? null : () => _toggle(p),
          child: Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: C.line), bottom: BorderSide(color: C.line)),
            ),
            child: Stack(children: [
              // The grab handle.
              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.only(top: 3),
                  width: 34,
                  height: 3,
                  decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Row(children: [
                  GestureDetector(onTap: () => _toggle(p), child: title),
                  Expanded(
                    child: !open
                        ? ListenableBuilder(
                            listenable: widget.files,
                            builder: (_, _) => Text(
                              shell
                                  ? '  ${session.shells.where((t) => !t.exited).length} open'
                                  : '  ${baseName(widget.files.cwd ?? session.dir)}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: C.dim, fontSize: 12),
                            ),
                          )
                        : shell
                            ? TermTabs(terms: terms, session: session, onNew: _newShell, onPick: _pickShell)
                            : Breadcrumbs(files: widget.files),
                  ),
                  IconButton(
                    tooltip: open ? 'Collapse' : 'Expand',
                    visualDensity: VisualDensity.compact,
                    icon: AnimatedRotation(
                      turns: open ? .5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: const Icon(Icons.expand_less_rounded, size: 22),
                    ),
                    onPressed: () => _toggle(p),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
