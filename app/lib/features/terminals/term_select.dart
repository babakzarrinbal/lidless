// Copying from a terminal: what xterm's own selection lacks. A drag that
// reaches the top or bottom edge scrolls the terminal and keeps selecting,
// right click opens Copy / Paste / Select all, and Cmd+C (Ctrl+Shift+C)
// copies. See README.md.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/ui/render.dart' show RenderTerminal; // ignore: implementation_imports
import 'package:xterm/xterm.dart';

import 'package:uniai/features/terminals/term_tab.dart';

/// Wraps one [TerminalView] (its [view] key and [scroll] controller) of [tab].
class TermSelect extends StatefulWidget {
  const TermSelect({
    super.key,
    required this.tab,
    required this.view,
    required this.scroll,
    required this.onCopy,
    required this.builder,
  });
  final TermTab tab;
  final GlobalKey<TerminalViewState> view;
  final ScrollController scroll;
  final VoidCallback onCopy;
  /// Builds the TerminalView; its onSecondaryTapDown opens the menu.
  final Widget Function(void Function(TapDownDetails, CellOffset) onSecondaryTapDown) builder;

  @override
  State<TermSelect> createState() => _TermSelectState();
}

class _TermSelectState extends State<TermSelect> {
  int? _ptr; // the pointer that may be selecting
  bool _touch = false; // touch selects words (long press), a mouse cells
  Offset? _pos; // where that pointer is, in the terminal's coordinates
  Offset _from = Offset.zero; // and where it went down
  bool _moved = false; // a press on the edge row alone does not scroll
  CellOffset? _base; // the cell the drag started on
  bool _selecting = false; // this drag made a selection
  bool _scrolled = false; // and scrolled since: xterm's own start is off now
  bool _applying = false;
  Timer? _tick;

  TerminalController get _c => widget.tab.controller;
  RenderTerminal? get _render => widget.view.currentState?.renderTerminal;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onSelection);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(TermSelect old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) {
      old.tab.controller.removeListener(_onSelection);
      _c.addListener(_onSelection);
      _end();
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onSelection);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _tick?.cancel();
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyC) return false;
    final k = HardwareKeyboard.instance;
    if (!(k.isMetaPressed || (k.isControlPressed && k.isShiftPressed))) return false;
    if (_c.selection == null || !mounted) return false;
    widget.onCopy();
    return true;
  }

  void _down(PointerDownEvent e) {
    if (_ptr != null) return;
    final touch = e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.stylus;
    if (!touch && e.buttons != kPrimaryButton) return;
    final r = _render;
    if (r == null) return;
    reattachLines(widget.tab.terminal);
    _ptr = e.pointer;
    _touch = touch;
    _pos = _from = r.globalToLocal(e.position);
    _base = r.getCellOffset(_pos!);
    _selecting = _scrolled = _moved = false;
    _tick = Timer.periodic(const Duration(milliseconds: 32), (_) => _autoscroll());
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _ptr) return;
    _pos = _render?.globalToLocal(e.position);
    if (_pos != null && (_pos! - _from).distance > 8) _moved = true;
  }

  void _up(PointerEvent e) {
    if (e.pointer == _ptr) _end();
  }

  void _end() {
    _tick?.cancel();
    _tick = null;
    _ptr = null;
  }

  void _onSelection() {
    if (_applying || _ptr == null || _c.selection == null) return;
    _selecting = true;
    // xterm keeps the drag's start in pixels: after a scroll it points at
    // another cell, so the selection is redone from the cell it began on.
    if (_scrolled) _apply();
  }

  /// While a selecting drag sits near the top or bottom edge, scroll toward
  /// it, faster the further out the pointer is.
  void _autoscroll() {
    final r = _render, p = _pos;
    if (!_selecting || !_moved || r == null || p == null || !widget.scroll.hasClients) return;
    final edge = r.lineHeight * 1.5, h = r.size.height;
    final out = p.dy < edge ? p.dy - edge : (p.dy > h - edge ? p.dy - (h - edge) : 0.0);
    if (out == 0) return;
    final pos = widget.scroll.position;
    final step = (out / 2).clamp(-2 * r.lineHeight, 2 * r.lineHeight);
    final to = (pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (to == pos.pixels) return;
    widget.scroll.jumpTo(to);
    _scrolled = true;
    _apply();
  }

  /// Selects from the drag's first cell to the one under the pointer: whole
  /// words for touch, as xterm's long press does, cells for a mouse.
  void _apply() {
    final r = _render, p = _pos, base = _base;
    if (r == null || p == null || base == null) return;
    final b = widget.tab.terminal.buffer;
    if (base.y >= b.lines.length) return;
    var from = base, to = r.getCellOffset(p);
    if (_touch) {
      final f = b.getWordBoundary(from), t = b.getWordBoundary(to);
      if (f == null || t == null) return;
      final m = f.merge(t);
      from = m.begin;
      to = m.end;
    } else if (to.y > from.y || (to.y == from.y && to.x >= from.x)) {
      to = CellOffset(to.x + 1, to.y);
    }
    _applying = true;
    _c.setSelection(b.createAnchorFromOffset(from), b.createAnchorFromOffset(to));
    _applying = false;
  }

  Future<void> _menu(TapDownDetails d, CellOffset _) async {
    final t = widget.tab;
    final hasSel = _c.selection != null;
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final paste = !t.exited && (clip?.text ?? '').isNotEmpty;
    final o = d.globalPosition;
    final a = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(o.dx, o.dy, o.dx, o.dy),
      items: [
        PopupMenuItem(value: 'copy', enabled: hasSel, child: const Text('Copy')),
        PopupMenuItem(value: 'paste', enabled: paste, child: const Text('Paste')),
        const PopupMenuItem(value: 'all', child: Text('Select all')),
      ],
    );
    if (!mounted) return;
    switch (a) {
      case 'copy':
        widget.onCopy();
      case 'paste':
        t.terminal.paste(clip!.text!);
      case 'all':
        selectAll(t);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: widget.builder(_menu),
    );
  }
}

/// Selects everything the terminal holds, scrollback included.
void selectAll(TermTab t) {
  reattachLines(t.terminal);
  final b = t.terminal.buffer;
  if (b.lines.length == 0) return;
  t.controller.setSelection(
    b.createAnchor(0, 0),
    b.createAnchor(b.viewWidth, b.lines.length - 1),
  );
}

