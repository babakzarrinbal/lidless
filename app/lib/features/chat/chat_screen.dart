// The terminal's screen inside the chat view, live, while there is no
// conversation to show yet: Claude or Copilot starting, loading a session,
// asking to trust a folder. See README.md.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'package:uniai/app/theme.dart';

/// The lines on [t]'s screen, right-trimmed, without blank lines at either
/// end and with runs of blank lines kept to one.
List<String> screenLines(Terminal t) {
  final b = t.buffer, out = <String>[];
  for (var i = (b.height - t.viewHeight).clamp(0, b.height); i < b.height; i++) {
    final l = b.lines[i].getText().trimRight();
    if (l.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
    out.add(l);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out;
}

/// A [hint] over the terminal's screen, redrawn as the terminal draws.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.terminal, required this.hint});
  final Terminal terminal;
  final String hint;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  Timer? _soon;
  List<String> _lines = const [];

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onScreen);
    _lines = screenLines(widget.terminal);
  }

  @override
  void didUpdateWidget(ChatScreen old) {
    super.didUpdateWidget(old);
    if (old.terminal != widget.terminal) {
      old.terminal.removeListener(_onScreen);
      widget.terminal.addListener(_onScreen);
      _lines = screenLines(widget.terminal);
    }
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onScreen);
    _soon?.cancel();
    super.dispose();
  }

  // A start-up screen redraws a spinner many times a second: a few frames do.
  void _onScreen() {
    if (_soon?.isActive ?? false) return;
    _soon = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _lines = screenLines(widget.terminal));
    });
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontFamily: mono, fontSize: 11.5, height: 1.35, color: C.text);
    return ListView(padding: const EdgeInsets.fromLTRB(14, 16, 14, 20), children: [
      Text(widget.hint, textAlign: TextAlign.center, style: const TextStyle(color: C.dim, height: 1.5)),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(8)),
        child: _lines.isEmpty
            ? const Text('(the terminal is blank)', style: TextStyle(color: C.dim, fontSize: 12))
            // Wide screens scroll sideways: wrapping breaks boxes and columns.
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(_lines.join('\n'), softWrap: false, style: style),
              ),
      ),
    ]);
  }
}
