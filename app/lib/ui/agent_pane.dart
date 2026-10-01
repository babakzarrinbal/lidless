import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../model/terms.dart';
import 'terminal_panel.dart';
import 'theme.dart';

/// The session's main pane: the agent's terminal (Claude Code, Copilot or a
/// plain shell; read-only until the keyboard key), quick keys, and a message
/// field. The field is the normal way to type: dictation, autocorrect and
/// editing work there, and Send hands the text over in one piece.
class AgentPane extends StatefulWidget {
  const AgentPane({
    super.key,
    required this.terms,
    required this.session,
    required this.fontSize,
    required this.onFocus,
    required this.onRestart,
  });
  final Terms terms;
  final Session session;
  final double fontSize;
  final VoidCallback onFocus;
  final VoidCallback onRestart;

  @override
  State<AgentPane> createState() => AgentPaneState();
}

class AgentPaneState extends State<AgentPane> {
  final _surface = GlobalKey<TermSurfaceState>();
  final _input = TextEditingController();
  final _inputFocus = FocusNode();

  Terms get terms => widget.terms;
  TermTab? get tab => widget.session.agent;
  bool get _cli => widget.session.tool == 'cli';

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(() {
      if (_inputFocus.hasFocus) widget.onFocus();
      setState(() {});
    });
    _input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _send() {
    final t = tab;
    if (t == null || t.exited) return;
    final text = _input.text;
    HapticFeedback.lightImpact();
    if (text.isEmpty) {
      terms.type(t, '\r');
      return;
    }
    // Bracketed paste keeps a multi-line message as one message; Enter goes
    // separately so Claude sees it as "submit", not as part of the text.
    if (text.contains('\n')) {
      terms.paste(t, text);
    } else {
      terms.type(t, text);
    }
    Future.delayed(Duration(milliseconds: text.length > 2000 ? 300 : 120), () => terms.type(t, '\r'));
    _input.clear();
    _inputFocus.unfocus(); // show Claude's answer, not the keyboard
  }

  Future<void> _pasteToInput() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final s = d?.text ?? '';
    if (s.isEmpty) return;
    final v = _input.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    _input.value = v.replaced(sel, s);
  }

  @override
  Widget build(BuildContext context) {
    final t = tab;
    final ended = t == null || t.exited;
    return Column(children: [
      Expanded(
        child: Stack(children: [
          Positioned.fill(
            child: TermSurface(
              key: _surface,
              tab: t,
              fontSize: widget.fontSize,
              onFocus: widget.onFocus,
              empty: terms.link.online ? 'Starting ${widget.session.toolName}…' : 'Waiting for your Mac…',
            ),
          ),
          if (ended && terms.synced)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: FilledButton.icon(
                  onPressed: widget.onRestart,
                  icon: const Icon(Icons.replay_rounded, size: 18),
                  label: Text(_cli ? 'Open the shell again' : 'Start ${widget.session.toolName} again (--continue)'),
                ),
              ),
            ),
        ]),
      ),
      KeyBar(keys: [
        TypingKey(surface: _surface),
        TKey(label: 'esc', onTap: () => terms.key(t, TerminalKey.escape)),
        TKey(label: '⇧tab', onTap: () => terms.type(t, '\x1b[Z')),
        ...arrowKeys(terms, t),
        TKey(icon: Icons.keyboard_return_rounded, onTap: () => terms.type(t, '\r')),
        for (final s in ['1', '2', '3']) TKey(label: s, onTap: () => terms.type(t, s)),
        TKey(label: '^C', color: C.red, onTap: () => terms.type(t, '\x03')),
        TKey(label: 'tab', onTap: () => terms.key(t, TerminalKey.tab)),
        TKey(icon: Icons.content_paste_rounded, onTap: () => pasteInto(context, terms, t)),
        for (final s in ['/', '@', '!', '#']) TKey(label: s, onTap: () => terms.type(t, s)),
        TKey(label: '^R', onTap: () => terms.type(t, '\x12')),
        TKey(icon: Icons.backspace_outlined, repeat: true, onTap: () => terms.key(t, TerminalKey.backspace)),
      ]),
      _inputBar(ended),
    ]);
  }

  Widget _inputBar(bool ended) {
    final focused = _inputFocus.hasFocus;
    return Container(
      color: C.panel,
      padding: const EdgeInsets.fromLTRB(8, 4, 6, 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: TextField(
            controller: _input,
            focusNode: _inputFocus,
            enabled: !ended,
            minLines: 1,
            maxLines: focused ? 6 : 2,
            keyboardType: TextInputType.multiline,
            textCapitalization: _cli ? TextCapitalization.none : TextCapitalization.sentences,
            autocorrect: !_cli,
            style: const TextStyle(fontSize: 15, height: 1.3),
            decoration: InputDecoration(
              isDense: true,
              hintText: _cli ? 'Command…' : 'Message ${widget.session.toolName}…',
              filled: true,
              fillColor: C.raised,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
              suffixIcon: focused && _input.text.isEmpty
                  ? IconButton(
                      tooltip: 'Paste',
                      icon: const Icon(Icons.content_paste_rounded, size: 19),
                      onPressed: _pasteToInput,
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filled(
          tooltip: _input.text.isEmpty ? 'Enter' : 'Send',
          onPressed: ended ? null : _send,
          icon: Icon(_input.text.isEmpty ? Icons.keyboard_return_rounded : Icons.arrow_upward_rounded, size: 20),
        ),
      ]),
    );
  }
}
