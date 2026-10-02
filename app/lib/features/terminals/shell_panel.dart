// A session's shell pane: the active shell with its key bar, and the sheet
// to compose a command.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:uniai/features/terminals/terminal_panel.dart';
import 'package:uniai/features/terminals/key_bar.dart';
import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/terminals/terms.dart';
import 'package:uniai/app/theme.dart';

/// A session's shell pane body: the active shell tab plus its key bar.
class ShellPanel extends StatefulWidget {
  const ShellPanel({
    super.key,
    required this.terms,
    required this.session,
    required this.fontSize,
    required this.onFocus,
  });
  final Terms terms;
  final Session session;
  final double fontSize;
  final VoidCallback onFocus;

  @override
  State<ShellPanel> createState() => ShellPanelState();
}

class ShellPanelState extends State<ShellPanel> {
  final _surface = GlobalKey<TermSurfaceState>();
  String _draft = '';

  Terms get terms => widget.terms;
  TermTab? get tab => terms.activeShell(widget.session);

  void showKeyboard() {
    if (_surface.currentState?.typing.value == false) _surface.currentState?.toggleKeyboard();
  }

  Future<void> _compose() async {
    final c = TextEditingController(text: _draft);
    final r = await composeSheet(context, c, title: 'Command', runLabel: 'Run');
    if (r == null) {
      _draft = c.text;
      return;
    }
    _draft = '';
    final (text, run) = r;
    if (text.isEmpty && !run) return;
    if (text.contains('\n')) {
      terms.paste(tab, text);
    } else {
      terms.type(tab, text);
    }
    if (run) terms.type(tab, '\r');
  }

  @override
  Widget build(BuildContext context) {
    final t = tab;
    return Column(children: [
      Expanded(
        child: TermSurface(
          key: _surface,
          tab: t,
          fontSize: widget.fontSize,
          onFocus: widget.onFocus,
          empty: terms.link.online ? 'Opening a shell…' : 'Waiting for your Mac…',
        ),
      ),
      KeyBar(keys: [
        // Most used first: what a phone keyboard lacks or hides.
        TypingKey(surface: _surface),
        TKey(icon: Icons.content_paste_rounded, onTap: () => pasteInto(context, terms, t)),
        TKey(icon: Icons.keyboard_return_rounded, onTap: () => terms.type(t, '\r')),
        TKey(label: '^C', color: C.red, onTap: () => terms.type(t, '\x03')),
        TKey(label: 'tab', onTap: () => terms.key(t, TerminalKey.tab)),
        TKey(icon: Icons.keyboard_arrow_up_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowUp)),
        TKey(icon: Icons.keyboard_arrow_down_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowDown)),
        TKey(icon: Icons.edit_note_rounded, color: C.accent, onTap: _compose),
        TKey(label: 'esc', onTap: () => terms.key(t, TerminalKey.escape)),
        TKey(label: '⌃', hint: 'control', active: terms.ctrl, onTap: terms.toggleCtrl),
        TKey(icon: Icons.keyboard_arrow_left_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowLeft)),
        TKey(icon: Icons.keyboard_arrow_right_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowRight)),
        for (final s in ['/', '-', '~', '|', '_', '*', '>', '&', r'$', '`'])
          TKey(label: s, onTap: () => t?.terminal.textInput(s)),
        TKey(icon: Icons.backspace_outlined, repeat: true, onTap: () => terms.key(t, TerminalKey.backspace)),
        TKey(label: '⌥', hint: 'option', active: terms.alt, onTap: terms.toggleAlt),
        TKey(label: '⌘', hint: 'command', active: terms.cmd, onTap: terms.toggleCmd),
        TKey(label: 'home', onTap: () => terms.key(t, TerminalKey.home)),
        TKey(label: 'end', onTap: () => terms.key(t, TerminalKey.end)),
        TKey(label: 'pgup', onTap: () => terms.key(t, TerminalKey.pageUp)),
        TKey(label: 'pgdn', onTap: () => terms.key(t, TerminalKey.pageDown)),
      ]),
    ]);
  }
}

/// A bottom sheet with a multi-line field: returns (text, run) or null.
Future<(String, bool)?> composeSheet(BuildContext context, TextEditingController c,
    {required String title, required String runLabel}) {
  return showModalBottomSheet<(String, bool)>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: const TextStyle(color: C.dim, fontSize: 13)),
        const SizedBox(height: 8),
        TextField(
          controller: c,
          autofocus: true,
          minLines: 2,
          maxLines: 8,
          autocorrect: false,
          textCapitalization: TextCapitalization.none,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontFamily: mono, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Type, dictate or paste — edit it here, then run',
            suffixIcon: IconButton(
              icon: const Icon(Icons.content_paste_rounded, size: 20),
              onPressed: () async {
                final d = await Clipboard.getData(Clipboard.kTextPlain);
                final s = d?.text ?? '';
                final v = c.value;
                final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
                c.value = v.replaced(sel, s);
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          TextButton(onPressed: () => c.clear(), child: const Text('Clear')),
          const Spacer(),
          OutlinedButton(onPressed: () => Navigator.pop(context, (c.text, false)), child: const Text('Insert')),
          const SizedBox(width: 8),
          FilledButton.icon(
              onPressed: () => Navigator.pop(context, (c.text, true)),
              icon: const Icon(Icons.keyboard_return_rounded, size: 18),
              label: Text(runLabel)),
        ]),
      ]),
    ),
  );
}
