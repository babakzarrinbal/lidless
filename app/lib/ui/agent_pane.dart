import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../model/chat.dart';
import '../model/claude.dart';
import '../model/terms.dart';
import '../net/link.dart';
import 'agent_extras.dart';
import 'chat_view.dart';
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
    required this.onConversation,
    this.onToShell,
  });
  final Terms terms;
  final Session session;
  final double fontSize;
  final VoidCallback onFocus;
  final VoidCallback onRestart;
  final ValueChanged<Conversation> onConversation; // picked from the folder's history
  final ValueChanged<String>? onToShell; // code from the chat, into the shell pane

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
  bool get _canChat => const {'claude', 'copilot'}.contains(widget.session.tool);
  bool _chatMode = true; // Claude shows as a chat; the terminal is one tap away
  bool get _chat => _canChat && _chatMode && tab != null;
  bool get _slashy => !_cli && _inputFocus.hasFocus && RegExp(r'^/\S*$').hasMatch(_input.text);
  List<SlashCommand>? _commands;
  bool _loadingCommands = false;

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(() {
      if (_inputFocus.hasFocus) widget.onFocus();
      setState(() {});
    });
    _input.addListener(() {
      setState(() {});
      if (_slashy) _loadCommands();
    });
  }

  Future<void> _loadCommands() async {
    if (_commands != null || _loadingCommands) return;
    _loadingCommands = true;
    try {
      final c = await SlashCommand.of(terms.link, widget.session.dir, widget.session.tool);
      if (mounted) setState(() => _commands = c);
    } on RpcError {
      // offline or an older agent: no popup
    } finally {
      _loadingCommands = false;
    }
  }

  void _pickCommand(SlashCommand c) {
    final text = '/${c.name} ';
    _input.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  Future<void> _history() async {
    final c = await pickConversation(context, terms.link, widget.session.dir, currentTerm: tab?.id);
    if (c != null && mounted) widget.onConversation(c);
  }

  Widget _pill({required IconData icon, String? label, required VoidCallback onTap, String? tip}) => Material(
        color: C.raised.withValues(alpha: 0.92),
        shape: const StadiumBorder(side: BorderSide(color: C.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Tooltip(
            message: tip ?? '',
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: label == null ? 8 : 10, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 15, color: C.dim),
                if (label != null) ...[
                  const SizedBox(width: 5),
                  Text(label, style: const TextStyle(fontSize: 12, color: C.dim)),
                ],
              ]),
            ),
          ),
        ),
      );

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
    // A bracketed paste marks where the text ends (and keeps a multi-line
    // message as one), so the Enter after it is "submit" even when a busy
    // Claude reads both at once. Enter goes separately; the agent keeps a gap.
    terms.paste(t, text);
    Future.delayed(Duration(milliseconds: text.length > 2000 ? 300 : 120), () => terms.type(t, '\r'));
    if (_chat) t.chat.sent(text);
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
          // The terminal stays laid out under the chat so its size, and
          // Claude's screen, do not change when switching.
          Positioned.fill(
            child: Offstage(
              offstage: _chat,
              child: TermSurface(
                key: _surface,
                tab: t,
                fontSize: widget.fontSize,
                onFocus: widget.onFocus,
                empty: terms.link.online ? 'Starting ${widget.session.toolName}…' : 'Waiting for your Mac…',
              ),
            ),
          ),
          if (_chat) Positioned.fill(child: ColoredBox(color: C.bg, child: ChatView(terms: terms, tab: t!, onToShell: widget.onToShell))),
          if (_canChat && t != null)
            Positioned(
              top: 6,
              right: 6,
              child: Row(children: [
                ListenableBuilder(
                  listenable: t.chat,
                  builder: (context, _) {
                    final u = t.chat.used;
                    if (u == null || u.total == 0) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _pill(
                        icon: Icons.data_usage_rounded,
                        label: tokenCount(u.total),
                        tip: 'Tokens this conversation used',
                        onTap: () => showTokenUse(context, u, tool: widget.session.toolName),
                      ),
                    );
                  },
                ),
                _pill(icon: Icons.history_rounded, tip: 'Conversations in this folder', onTap: _history),
                const SizedBox(width: 6),
                _pill(
                  icon: _chat ? Icons.terminal_rounded : Icons.forum_outlined,
                  label: _chat ? 'Terminal' : 'Chat',
                  onTap: () => setState(() => _chatMode = !_chatMode),
                ),
              ]),
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
          if (_slashy && _commands != null)
            Builder(builder: (context) {
              final m = SlashCommand.match(_commands!, _input.text);
              if (m.isEmpty) return const SizedBox.shrink();
              return Positioned(left: 6, right: 6, bottom: 0, child: SlashList(commands: m, onPick: _pickCommand));
            }),
        ]),
      ),
      // The chat needs no keyboard keys (Stop and the answers are in it); the terminal does.
      if (!_chat) KeyBar(keys: [
        TypingKey(surface: _surface),
        TKey(label: 'esc', onTap: () => terms.key(t, TerminalKey.escape)),
        TKey(label: '⇧tab', onTap: () => terms.type(t, '\x1b[Z')),
        ...arrowKeys(terms, t),
        TKey(icon: Icons.keyboard_return_rounded, onTap: () => terms.type(t, '\r')),
        for (final s in ['1', '2', '3']) TKey(label: s, onTap: () => terms.type(t, s)),
        TKey(label: '^C', color: C.red, onTap: () => terms.type(t, '\x03')),
        ...macMods(terms),
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
        if (_canChat && tab != null)
          ListenableBuilder(
            listenable: tab!.chat,
            builder: (context, _) {
              final u = tab!.chat.ctx;
              return u == null
                  ? const SizedBox.shrink()
                  : Padding(padding: const EdgeInsets.only(left: 6, bottom: 2), child: ContextRing(u));
            },
          ),
        const SizedBox(width: 6),
        // While the agent works, an empty box's button stops it (esc); a typed
        // message still sends (the agent queues it).
        ListenableBuilder(
          listenable: terms,
          builder: (context, _) {
            final t = tab;
            if (!ended && !_cli && t != null && t.working && _input.text.isEmpty) {
              return IconButton.filled(
                key: const ValueKey('stop'),
                tooltip: 'Stop',
                style: IconButton.styleFrom(backgroundColor: C.red, foregroundColor: Colors.white),
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  terms.key(t, TerminalKey.escape);
                },
                icon: const Icon(Icons.stop_rounded, size: 20),
              );
            }
            return IconButton.filled(
              tooltip: _input.text.isEmpty ? 'Enter' : 'Send',
              onPressed: ended ? null : _send,
              icon: Icon(_input.text.isEmpty ? Icons.keyboard_return_rounded : Icons.arrow_upward_rounded, size: 20),
            );
          },
        ),
      ]),
    );
  }
}
