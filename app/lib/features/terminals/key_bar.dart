// The key bar under a terminal: modifier keys, arrows, paste, and the keys
// that hold down to repeat.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:uniai/features/terminals/terminal_panel.dart';
import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/terminals/terms.dart';
import 'package:uniai/app/theme.dart';

/// The Mac's modifier keys, one-shot: ⌃ control, ⌥ option, ⌘ command.
List<Widget> macMods(Terms terms) => [
      TKey(label: '⌃', hint: 'control', active: terms.ctrl, onTap: terms.toggleCtrl),
      TKey(label: '⌥', hint: 'option', active: terms.alt, onTap: terms.toggleAlt),
      TKey(label: '⌘', hint: 'command', active: terms.cmd, onTap: terms.toggleCmd),
    ];

/// The key bar's keyboard button for a [TermSurface]; lit while typing.
class TypingKey extends StatefulWidget {
  const TypingKey({super.key, required this.surface});
  final GlobalKey<TermSurfaceState> surface;
  @override
  State<TypingKey> createState() => _TypingKeyState();
}

class _TypingKeyState extends State<TypingKey> {
  ValueNotifier<bool>? _n;

  @override
  void initState() {
    super.initState();
    // The surface is built in the same frame; pick up its notifier after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _n = widget.surface.currentState?.typing);
    });
  }

  @override
  Widget build(BuildContext context) {
    final n = _n ?? widget.surface.currentState?.typing;
    Widget key(bool on) => TKey(
          icon: on ? Icons.keyboard_hide_rounded : Icons.keyboard_rounded,
          active: on,
          onTap: () => widget.surface.currentState?.toggleKeyboard(),
        );
    if (n == null) return key(false);
    return ValueListenableBuilder<bool>(valueListenable: n, builder: (_, on, _) => key(on));
  }
}

List<Widget> arrowKeys(Terms terms, TermTab? t) => [
      TKey(icon: Icons.keyboard_arrow_up_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowUp)),
      TKey(icon: Icons.keyboard_arrow_down_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowDown)),
      TKey(icon: Icons.keyboard_arrow_left_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowLeft)),
      TKey(icon: Icons.keyboard_arrow_right_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowRight)),
    ];

Future<void> pasteInto(BuildContext context, Terms terms, TermTab? t) async {
  final d = await Clipboard.getData(Clipboard.kTextPlain);
  final s = d?.text;
  if (s == null || s.isEmpty) {
    if (context.mounted) toast(context, 'Clipboard is empty');
    return;
  }
  terms.paste(t, s);
}

class KeyBar extends StatelessWidget {
  const KeyBar({super.key, required this.keys});
  final List<Widget> keys;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: C.panel,
        border: Border(top: BorderSide(color: C.line)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        children: keys,
      ),
    );
  }
}

class TKey extends StatefulWidget {
  const TKey({
    super.key,
    this.label,
    this.icon,
    required this.onTap,
    this.active = false,
    this.repeat = false,
    this.color,
    this.hint,
  });
  final String? label, hint;
  final IconData? icon;
  final VoidCallback onTap;
  final bool active, repeat;
  final Color? color;

  @override
  State<TKey> createState() => _TKeyState();
}

class _TKeyState extends State<TKey> {
  Timer? _t;

  void _start() {
    _t?.cancel();
    _t = Timer.periodic(const Duration(milliseconds: 70), (_) => widget.onTap());
  }

  void _stop() {
    _t?.cancel();
    _t = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.active ? C.bg : (widget.color ?? C.text);
    final key = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onLongPressStart: widget.repeat ? (_) => _start() : null,
        onLongPressEnd: widget.repeat ? (_) => _stop() : null,
        onLongPressCancel: widget.repeat ? _stop : null,
        child: Material(
          color: widget.active ? C.accent : C.raised,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onTap();
            },
            child: Container(
              constraints: const BoxConstraints(minWidth: 40),
              padding: const EdgeInsets.symmetric(horizontal: 9),
              alignment: Alignment.center,
              child: widget.icon != null
                  ? Icon(widget.icon, size: 20, color: fg)
                  : Text(widget.label!,
                      style: TextStyle(
                          fontFamily: mono,
                          fontSize: 13.5,
                          color: fg,
                          fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
    return widget.hint == null ? key : Tooltip(message: widget.hint!, child: key);
  }
}
