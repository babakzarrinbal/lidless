import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/terms.dart';
import '../net/link.dart';
import 'files_panel.dart';
import 'terminal_panel.dart';
import 'theme.dart';

enum Panel { term, files }

/// The main screen: a terminal panel and a files panel, each collapsible, with
/// a draggable split. While the keyboard is up only the focused panel shows.
class Home extends StatefulWidget {
  const Home({
    super.key,
    required this.link,
    required this.terms,
    required this.files,
    required this.onLock,
    required this.onUnpair,
  });
  final Link link;
  final Terms terms;
  final Files files;
  final VoidCallback onLock, onUnpair;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _termKey = GlobalKey<TerminalPanelState>();
  bool _termOpen = true, _filesOpen = true;
  double _split = .58, _font = 13;
  Panel _focus = Panel.term;
  Panel? _max;
  SharedPreferences? _prefs;

  Link get link => widget.link;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _prefs = p;
        _termOpen = p.getBool('termOpen') ?? true;
        _filesOpen = p.getBool('filesOpen') ?? true;
        _split = p.getDouble('split') ?? .58;
        _font = p.getDouble('font') ?? 13;
      });
    });
  }

  void _toggle(Panel p) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      if (_max != null) _max = null;
      if (p == Panel.term) {
        _termOpen = !_termOpen;
        _prefs?.setBool('termOpen', _termOpen);
      } else {
        _filesOpen = !_filesOpen;
        _prefs?.setBool('filesOpen', _filesOpen);
      }
    });
  }

  void _maximize(Panel p) => setState(() {
        _max = _max == p ? null : p;
        if (p == Panel.term) _termOpen = true;
        if (p == Panel.files) _filesOpen = true;
      });

  void _focused(Panel p) {
    if (_focus != p) setState(() => _focus = p);
  }

  void _font_(double d) {
    setState(() => _font = (_font + d).clamp(9, 22));
    _prefs?.setDouble('font', _font);
  }

  /// Opens the terminal panel and types [cmd] into it.
  Future<void> _runInTerminal(String cmd, {bool newTab = false}) async {
    setState(() {
      _termOpen = true;
      _focus = Panel.term;
      if (_max == Panel.files) _max = null;
    });
    try {
      if (newTab || widget.terms.current == null || widget.terms.current!.exited) {
        await widget.terms.open();
      }
      widget.terms.type(cmd);
      WidgetsBinding.instance.addPostFrameCallback((_) => _termKey.currentState?.showKeyboard());
    } on RpcError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  Future<void> _back() async {
    if (await widget.files.back()) return;
    if (_max != null) {
      setState(() => _max = null);
      return;
    }
    SystemNavigator.pop();
  }

  // ---- layout ----

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            _topBar(),
            ListenableBuilder(listenable: link, builder: (_, _) => _banner()),
            Expanded(child: LayoutBuilder(builder: (context, c) => _panels(c.biggest))),
          ]),
        ),
      ),
    );
  }

  Widget _topBar() {
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        final (color, label) = switch (link.state) {
          LinkState.online => (C.green, 'connected'),
          LinkState.connecting => (C.amber, 'connecting…'),
          LinkState.offline => (C.red, 'offline'),
          LinkState.refused => (C.red, 'refused'),
        };
        return Container(
          height: 48,
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: color.withValues(alpha: .6), blurRadius: 8)],
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(link.host,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: C.dim, fontSize: 12)),
            const Spacer(),
            IconButton(
              tooltip: 'Mac status',
              icon: const Icon(Icons.laptop_mac_rounded, size: 21),
              onPressed: link.online ? _statusSheet : null,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) => switch (v) {
                'bigger' => _font_(1),
                'smaller' => _font_(-1),
                'lock' => widget.onLock(),
                'unpair' => _unpair(),
                _ => null,
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  enabled: false,
                  child: Row(children: [
                    const Text('Text size', style: TextStyle(color: C.text)),
                    const Spacer(),
                    Text('${_font.round()}', style: const TextStyle(color: C.dim)),
                  ]),
                ),
                const PopupMenuItem(value: 'bigger', child: Text('Larger text  A+')),
                const PopupMenuItem(value: 'smaller', child: Text('Smaller text  A−')),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'lock', child: Text('Lock now')),
                const PopupMenuItem(value: 'unpair', child: Text('Unpair this Mac…')),
              ],
            ),
          ]),
        );
      },
    );
  }

  Widget _banner() {
    final s = link.state;
    if (s == LinkState.online) return const SizedBox.shrink();
    if (s == LinkState.connecting && link.error == null) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    final refused = s == LinkState.refused;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: (refused ? C.red : C.amber).withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(refused ? Icons.block_rounded : Icons.cloud_off_rounded,
            size: 18, color: refused ? C.red : C.amber),
        const SizedBox(width: 10),
        Expanded(
          child: Text(link.error ?? 'Not connected',
              style: const TextStyle(fontSize: 13), maxLines: 3, overflow: TextOverflow.ellipsis),
        ),
        if (refused)
          TextButton(onPressed: widget.onUnpair, child: const Text('Pair again'))
        else
          TextButton(
            onPressed: s == LinkState.connecting ? null : link.reconnectNow,
            child: Text(s == LinkState.connecting ? 'Retrying…' : 'Retry'),
          ),
      ]),
    );
  }

  static const _hh = 40.0, _grip = 14.0;

  Widget _panels(Size size) {
    final kb = MediaQuery.viewInsetsOf(context).bottom > 0;
    final wide = size.width > 700;
    final solo = _max ?? (kb && _termOpen && _filesOpen ? _focus : null);
    final W = size.width, H = size.height;

    // Rects for both panels as if both were open (hidden bodies keep these so
    // the Mac's terminal size doesn't churn).
    late Rect th, tb, fh, fb;
    late Rect grip;
    if (wide) {
      final w = (W - _grip) * _split;
      th = Rect.fromLTWH(0, 0, w, _hh);
      tb = Rect.fromLTWH(0, _hh, w, H - _hh);
      fh = Rect.fromLTWH(w + _grip, 0, W - w - _grip, _hh);
      fb = Rect.fromLTWH(w + _grip, _hh, W - w - _grip, H - _hh);
      grip = Rect.fromLTWH(w, 0, _grip, H);
    } else {
      final avail = H - 2 * _hh - _grip;
      final t = avail * _split;
      th = Rect.fromLTWH(0, 0, W, _hh);
      tb = Rect.fromLTWH(0, _hh, W, t);
      grip = Rect.fromLTWH(0, _hh + t, W, _grip);
      fh = Rect.fromLTWH(0, _hh + t + _grip, W, _hh);
      fb = Rect.fromLTWH(0, 2 * _hh + t + _grip, W, avail - t);
    }
    var showTH = true, showFH = true, showTB = _termOpen, showFB = _filesOpen, showGrip = true;
    final full = Rect.fromLTWH(0, _hh, W, H - _hh);

    if (solo != null) {
      showGrip = false;
      if (solo == Panel.term) {
        showFH = showFB = false;
        th = Rect.fromLTWH(0, 0, W, _hh);
        tb = full;
      } else {
        showTH = showTB = false;
        fh = Rect.fromLTWH(0, 0, W, _hh);
        fb = full;
      }
    } else if (!(_termOpen && _filesOpen)) {
      showGrip = false;
      if (wide) {
        const cw = 170.0;
        if (_termOpen) {
          th = Rect.fromLTWH(0, 0, W - cw, _hh);
          fh = Rect.fromLTWH(W - cw, 0, cw, _hh);
          tb = full;
        } else if (_filesOpen) {
          th = Rect.fromLTWH(0, 0, cw, _hh);
          fh = Rect.fromLTWH(cw, 0, W - cw, _hh);
          fb = full;
        } else {
          th = Rect.fromLTWH(0, 0, W / 2, _hh);
          fh = Rect.fromLTWH(W / 2, 0, W / 2, _hh);
        }
      } else {
        th = Rect.fromLTWH(0, 0, W, _hh);
        if (_termOpen) {
          tb = Rect.fromLTWH(0, _hh, W, H - 2 * _hh);
          fh = Rect.fromLTWH(0, H - _hh, W, _hh);
        } else {
          fh = Rect.fromLTWH(0, _hh, W, _hh);
          if (_filesOpen) fb = Rect.fromLTWH(0, 2 * _hh, W, H - 2 * _hh);
        }
      }
    }

    Widget place(Rect r, bool show, Widget child) => Positioned.fromRect(
          rect: r,
          child: Offstage(offstage: !show, child: TickerMode(enabled: show, child: child)),
        );

    final bottomPad = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: kb ? 0 : bottomPad),
      child: Stack(children: [
        place(tb, showTB, Container(
          color: C.bg,
          child: TerminalPanel(
            key: _termKey,
            terms: widget.terms,
            fontSize: _font,
            onFocus: () => _focused(Panel.term),
          ),
        )),
        place(fb, showFB, Container(
          color: C.bg,
          child: FilesPanel(
            files: widget.files,
            fontSize: _font,
            onFocus: () => _focused(Panel.files),
            onCdInTerminal: (dir) => _runInTerminal('cd ${shellQuote(dir)}\r'),
          ),
        )),
        place(th, showTH, _header(Panel.term)),
        place(fh, showFH, _header(Panel.files)),
        place(grip, showGrip, _gripper(wide, size)),
      ]),
    );
  }

  Widget _gripper(bool wide, Size size) {
    final extent = wide ? size.width - _grip : size.height - 2 * _hh - _grip;
    void drag(double d) => setState(() => _split = (_split + d / extent).clamp(.15, .85));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: wide ? null : (d) => drag(d.delta.dy),
      onHorizontalDragUpdate: wide ? (d) => drag(d.delta.dx) : null,
      onVerticalDragEnd: wide ? null : (_) => _prefs?.setDouble('split', _split),
      onHorizontalDragEnd: wide ? (_) => _prefs?.setDouble('split', _split) : null,
      onDoubleTap: () {
        setState(() => _split = .58);
        _prefs?.setDouble('split', _split);
      },
      child: Container(
        color: C.bg,
        alignment: Alignment.center,
        child: Container(
          width: wide ? 4 : 44,
          height: wide ? 44 : 4,
          decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(2)),
        ),
      ),
    );
  }

  Widget _header(Panel p) {
    final term = p == Panel.term;
    final open = term ? _termOpen : _filesOpen;
    final maxed = _max == p;
    return Material(
      color: C.panel,
      child: InkWell(
        onTap: open ? null : () => _toggle(p),
        child: Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: C.line), bottom: BorderSide(color: C.line)),
          ),
          padding: const EdgeInsets.only(left: 12),
          child: Row(children: [
            GestureDetector(
              onTap: () => _toggle(p),
              child: Row(children: [
                Icon(term ? Icons.terminal_rounded : Icons.folder_open_rounded,
                    size: 18, color: term ? C.green : C.amber),
                const SizedBox(width: 8),
                if (!open)
                  Text(term ? 'Terminal' : 'Files',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              ]),
            ),
            Expanded(
              child: !open
                  ? (term
                      ? ListenableBuilder(
                          listenable: widget.terms,
                          builder: (_, _) => Text(
                            '  ${widget.terms.tabs.length} open',
                            style: const TextStyle(color: C.dim, fontSize: 12),
                          ),
                        )
                      : const SizedBox())
                  : term
                      ? TermTabs(terms: widget.terms)
                      : Breadcrumbs(files: widget.files),
            ),
            if (open)
              IconButton(
                tooltip: maxed ? 'Restore' : 'Maximize',
                visualDensity: VisualDensity.compact,
                icon: Icon(maxed ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded, size: 17),
                onPressed: () => _maximize(p),
              ),
            IconButton(
              tooltip: open ? 'Collapse' : 'Expand',
              visualDensity: VisualDensity.compact,
              icon: AnimatedRotation(
                turns: open ? 0 : .5,
                duration: const Duration(milliseconds: 180),
                child: const Icon(Icons.expand_less_rounded, size: 22),
              ),
              onPressed: () => _toggle(p),
            ),
          ]),
        ),
      ),
    );
  }

  // ---- menus ----

  Future<void> _unpair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unpair ${link.host}?'),
        content: const Text(
            'This phone forgets the Mac and its own key. Terminals on the Mac keep running. '
            'To connect again you need a new pairing code.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onUnpair();
  }

  Future<void> _statusSheet() async {
    Map? s;
    try {
      s = await link.call('sys.status', null, const Duration(seconds: 8)) as Map;
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
      return;
    }
    if (!mounted) return;
    final lid = s['lidAwake'] == true;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s!['host'] ?? link.host, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            _row(Icons.battery_charging_full_rounded, 'Battery', s['battery'] ?? '—'),
            _row(Icons.power_rounded, 'Power', s['power'] ?? '—'),
            _row(Icons.coffee_rounded, 'Kept awake while idle', s['keepAwake'] == true ? 'yes' : 'no'),
            const Divider(height: 28),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: lid,
              title: const Text('Stay awake with the lid closed'),
              subtitle: Text(
                lid
                    ? 'On. Sleep is disabled until you switch this off.'
                    : 'Runs “sudo pmset -a disablesleep 1” in a new terminal; type your Mac password there.',
                style: const TextStyle(fontSize: 12.5, color: C.dim),
              ),
              onChanged: (v) {
                Navigator.pop(ctx);
                _runInTerminal('sudo pmset -a disablesleep ${v ? 1 : 0}\r', newTab: true);
                toast(context, 'Enter your Mac password in the terminal');
              },
            ),
            if (lid)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'A closed MacBook in a bag can get hot. Switch this off when you are done.',
                  style: TextStyle(color: C.amber, fontSize: 12.5),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _row(IconData i, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Icon(i, size: 18, color: C.dim),
          const SizedBox(width: 12),
          Text(k, style: const TextStyle(color: C.dim)),
          const Spacer(),
          Flexible(child: Text(v, textAlign: TextAlign.end, overflow: TextOverflow.ellipsis)),
        ]),
      );
}
