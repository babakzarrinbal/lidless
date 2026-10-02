// Copying from a terminal. This layer owns selection: xterm's own gestures
// select from pixel positions and lose their start when the view scrolls, so
// they never get the pointers that select.
//  - Mouse (a Mac): drag selects, double click a word, triple click a line,
//    shift+click moves the nearer end. A plain click goes to an app that reads
//    the mouse, or focuses the terminal.
//  - Touch: a long press selects a word and drags on by words; then a handle
//    at each end moves that end.
//  - Any selecting drag near the top or bottom edge scrolls and selects on.
//  - Right click: Copy / Paste / Select all. Cmd+C (Ctrl+Shift+C) copies.
// select_range.dart has the cell math, select_handles.dart the pieces,
// term_menu.dart the right-click menu.
// See README.md.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/ui/render.dart' show RenderTerminal; // ignore: implementation_imports
import 'package:xterm/xterm.dart';

import 'package:uniai/features/terminals/select_handles.dart';
import 'package:uniai/features/terminals/select_range.dart';
import 'package:uniai/features/terminals/term_menu.dart';
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
  final _box = GlobalKey(); // handles are placed in this Stack's coordinates
  bool _touch = false; // the last pointer was a finger: show the handles

  // The selection being made: [_anchor] stays, the end at [_pos] follows.
  Span? _anchor;
  SelUnit _unit = SelUnit.char;
  Offset? _pos; // global
  Offset _grab = Offset.zero; // a handle's offset from the caret it moves
  Offset _from = Offset.zero; // where the drag began
  bool _moved = false; // a press on the edge row alone does not scroll
  Timer? _tick;

  // The mouse: clicks counted for double and triple click.
  int _clicks = 0;
  Duration _lastDown = Duration.zero;
  bool _shift = false, _hadSel = false;

  TerminalController get _c => widget.tab.controller;
  RenderTerminal? get _render => widget.view.currentState?.renderTerminal;

  @override
  void initState() {
    super.initState();
    _c.addListener(_relayout);
    widget.scroll.addListener(_relayout);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(TermSelect old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) {
      old.tab.controller.removeListener(_relayout);
      _c.addListener(_relayout);
      _stop();
    }
    if (old.scroll != widget.scroll) {
      old.scroll.removeListener(_relayout);
      widget.scroll.addListener(_relayout);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_relayout);
    widget.scroll.removeListener(_relayout);
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

  /// Moves the handles with the selection and the scroll. Not mid-layout: a
  /// scroll can land there.
  void _relayout() {
    if (!_touch || !mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
    }
  }

  /// The span [unit] covers under the global point [g].
  Span? _spanAt(Offset g, SelUnit unit) {
    final r = _render;
    if (r == null || !r.attached) return null;
    final p = r.globalToLocal(g);
    final cell = r.getCellOffset(p);
    final right = p.dx - r.getOffset(cell).dx > r.cellSize.width / 2;
    return spanAt(widget.tab.terminal.buffer, cell, unit, right: right);
  }

  void _begin(Span anchor, SelUnit unit, Offset pos, {Offset grab = Offset.zero}) {
    _anchor = anchor;
    _unit = unit;
    _pos = _from = pos;
    _grab = grab;
    _moved = false;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 32), (_) => _autoscroll());
    _extend();
  }

  void _moveTo(Offset pos) {
    _pos = pos;
    if ((pos - _from).distance > 8) _moved = true;
    _extend();
  }

  void _stop() {
    _tick?.cancel();
    _tick = null;
    _anchor = _pos = null;
  }

  /// Selects from the anchor to the span under the moving end.
  void _extend() {
    final a = _anchor, p = _pos;
    if (a == null || p == null) return;
    final c = _spanAt(p - _grab, _unit);
    if (c == null) return;
    final s = joinSpans(a, c);
    final b = widget.tab.terminal.buffer;
    if (s.begin.isEqual(s.end)) {
      if (_c.selection != null) _c.clearSelection();
      return;
    }
    if (s.end.y >= b.lines.length) return;
    final now = _c.selection;
    if (now != null && now.begin.isEqual(s.begin) && now.end.isEqual(s.end)) return;
    _c.setSelection(b.createAnchorFromOffset(s.begin), b.createAnchorFromOffset(s.end));
  }

  /// While a selecting drag sits near the top or bottom edge, scroll toward
  /// it, faster the further out the pointer is.
  void _autoscroll() {
    final r = _render, g = _pos;
    if (!_moved || r == null || g == null || !r.attached || !widget.scroll.hasClients) return;
    final p = r.globalToLocal(g - _grab);
    final edge = r.lineHeight * 1.5, h = r.size.height;
    final out = p.dy < edge ? p.dy - edge : (p.dy > h - edge ? p.dy - (h - edge) : 0.0);
    if (out == 0) return;
    final pos = widget.scroll.position;
    final step = (out / 2).clamp(-2 * r.lineHeight, 2 * r.lineHeight);
    final to = (pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (to == pos.pixels) return;
    widget.scroll.jumpTo(to);
    _extend();
  }

  void _seen(PointerDownEvent e) {
    reattachLines(widget.tab.terminal);
    final touch = e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.stylus;
    if (touch != _touch) setState(() => _touch = touch);
  }

  // ---- mouse ----

  void _mouseDown(PointerDownEvent e) {
    final again = e.timeStamp - _lastDown < const Duration(milliseconds: 400) &&
        (e.position - _from).distance < kDoubleTapSlop;
    _clicks = again ? _clicks % 3 + 1 : 1;
    _lastDown = e.timeStamp;
    final sel = _c.selection;
    _hadSel = sel != null;
    _shift = HardwareKeyboard.instance.isShiftPressed;
    if (_shift && sel != null) {
      final at = _spanAt(e.position, SelUnit.char);
      if (at == null) return;
      final keep = farEnd(sel, at.begin, widget.tab.terminal.viewWidth);
      _clicks = 1;
      _begin((begin: keep, end: keep), SelUnit.char, e.position);
      _moved = true;
      return;
    }
    final unit = SelUnit.values[_clicks - 1];
    final s = _spanAt(e.position, unit);
    if (s != null) _begin(s, unit, e.position); // a caret: clears the selection
  }

  void _mouseMove(Offset g) {
    if (_anchor == null) return;
    // A cell's worth of wobble in a click selects nothing.
    if (_unit == SelUnit.char && !_moved && (g - _from).distance <= 3) return;
    _moveTo(g);
    _moved = true;
  }

  void _mouseUp(bool cancelled) {
    final click = !cancelled && _clicks == 1 && !_moved && !_shift && _anchor != null;
    _stop();
    final v = widget.view.currentState;
    if (!click || _hadSel || v == null) return; // that click only cleared the selection
    final r = v.renderTerminal, at = r.globalToLocal(_from);
    final sendTaps = !v.widget.readOnly && !_c.suspendedPointerInputs && _c.pointerInput.inputs.contains(PointerInput.tap);
    if (sendTaps && r.mouseEvent(TerminalMouseButton.left, TerminalMouseButtonState.down, at)) {
      r.mouseEvent(TerminalMouseButton.left, TerminalMouseButtonState.up, at);
      return;
    }
    v.requestKeyboard();
  }

  // ---- touch ----

  void _pressStart(LongPressStartDetails d) {
    final s = _spanAt(d.globalPosition, SelUnit.word);
    if (s == null) return;
    HapticFeedback.selectionClick();
    _begin(s, SelUnit.word, d.globalPosition);
  }

  /// A finger took the handle at the selection's begin ([isBegin]) or end.
  void _grabHandle(bool isBegin, PointerDownEvent e) {
    final sel = _c.selection?.normalized, r = _render;
    if (sel == null || r == null) return;
    final keep = isBegin ? sel.end : sel.begin, moving = isBegin ? sel.begin : sel.end;
    final caret = r.localToGlobal(r.getOffset(moving) + Offset(0, r.lineHeight / 2));
    _begin((begin: keep, end: keep), SelUnit.char, e.position, grab: e.position - caret);
  }

  List<Widget> _handles() {
    final sel = _c.selection?.normalized, r = _render;
    final box = _box.currentContext?.findRenderObject() as RenderBox?;
    if (!_touch || sel == null || r == null || box == null || !r.attached || !box.hasSize) return const [];
    Offset below(CellOffset o) => box.globalToLocal(r.localToGlobal(r.getOffset(o) + Offset(0, r.lineHeight)));
    return [
      for (final (o, isBegin) in [(sel.begin, true), (sel.end, false)])
        if (below(o) case final at when at.dy >= 0 && at.dy <= box.size.height)
          SelHandle(
            key: ValueKey(isBegin ? 'sel-begin' : 'sel-end'),
            at: at,
            onDown: (e) => _grabHandle(isBegin, e),
            onMove: _moveTo,
            onUp: (_) => _stop(),
          ),
    ];
  }

  void _menu(TapDownDetails d, CellOffset _) => showTermMenu(context, d.globalPosition, widget.tab, widget.onCopy);

  @override
  Widget build(BuildContext context) {
    return Stack(key: _box, children: [
      Positioned.fill(
        child: Listener(
          onPointerDown: _seen,
          child: RawGestureDetector(
            gestures: {
              Grab: GestureRecognizerFactoryWithHandlers<Grab>(
                () => Grab(supportedDevices: {PointerDeviceKind.mouse}),
                (g) => g
                  ..onDown = _mouseDown
                  ..onMove = _mouseMove
                  ..onUp = _mouseUp,
              ),
              // Sooner than xterm's own long press (500 ms), so this one wins.
              LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: const Duration(milliseconds: 400),
                  supportedDevices: {PointerDeviceKind.touch, PointerDeviceKind.stylus},
                ),
                (g) => g
                  ..onLongPressStart = _pressStart
                  ..onLongPressMoveUpdate = ((d) => _moveTo(d.globalPosition))
                  ..onLongPressEnd = ((_) => _stop())
                  ..onLongPressCancel = _stop,
              ),
            },
            child: widget.builder(_menu),
          ),
        ),
      ),
      ..._handles(),
    ]);
  }
}
