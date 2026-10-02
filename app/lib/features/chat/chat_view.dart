// The chat view: transcript, input and the working/ask status.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' show TerminalKey;

import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/chat/chat.dart';
import 'package:uniai/features/terminals/terms.dart';
import 'package:uniai/app/theme.dart';
import 'package:uniai/features/chat/chat_messages.dart';
import 'package:uniai/features/chat/chat_tools.dart';
import 'package:uniai/features/chat/chat_status.dart';

/// The agent's conversation the way the Claude app shows it: your messages,
/// formatted answers, and one compact row per tool call that opens to show
/// the command, the diff and the output. It follows the transcript Claude
/// Code writes on the Mac and polls whenever the terminal draws something.
class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.terms, required this.tab, this.onToShell});
  final Terms terms;
  final TermTab tab;
  final ValueChanged<String>? onToShell; // code, into the session's shell pane

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scroll = ScrollController();
  Timer? _soon, _every;
  bool _atBottom = true;
  // The working line's text changes every second: only its row listens.
  final _live = ValueNotifier(const LiveScreen());

  ChatLog get log => widget.tab.chat;

  @override
  void initState() {
    super.initState();
    _attach();
    // The list is reversed: offset 0 is the newest end.
    _scroll.addListener(() {
      final p = _scroll.position, at = p.pixels <= 80;
      if (at != _atBottom) setState(() => _atBottom = at);
      if (p.pixels >= p.maxScrollExtent - 400) _older(); // near the top: read back
    });
  }

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) {
      _detach(old.tab);
      _attach();
    }
  }

  void _attach() {
    widget.tab.chat.addListener(_onLog);
    widget.tab.terminal.addListener(_onScreen);
    _every = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
    _atBottom = true;
    _poll();
    _onScreen();
  }

  void _detach(TermTab t) {
    t.chat.removeListener(_onLog);
    t.terminal.removeListener(_onScreen);
    _every?.cancel();
    _soon?.cancel();
  }

  @override
  void dispose() {
    _detach(widget.tab);
    _scroll.dispose();
    _live.dispose();
    super.dispose();
  }

  void _poll() => log.poll(widget.terms.link, widget.tab.id);

  void _older() {
    if (log.hasOlder) log.older(widget.terms.link, widget.tab.id);
  }

  // The screen changes many times a second while Claude works: read the
  // transcript and the screen at most a few times a second.
  void _onScreen() {
    if (_soon?.isActive ?? false) return;
    _soon = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _poll();
      final live = LiveScreen.of(widget.tab.terminal), was = _live.value;
      if (live.status == was.status && live.question == was.question && live.options.length == was.options.length) {
        return;
      }
      // Rows come or go: rebuild the list; otherwise only the working line.
      final rows = (live.status != null) != (was.status != null) ||
          live.asking != was.asking ||
          live.question != was.question ||
          live.options.length != was.options.length;
      _live.value = live;
      if (rows) setState(() {});
    });
  }

  void _onLog() => setState(() {});

  void _toBottom() {
    setState(() => _atBottom = true);
    _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final items = log.items;
    if (log.loaded && log.path.isEmpty && log.queued.isEmpty) {
      return _empty('Nothing here yet: send ${widget.terms.session(widget.tab.session)?.toolName ?? 'the agent'} a message below.\nIts start-up screen (a folder trust question, say) is under Terminal at the top right.');
    }
    if (!log.loaded) return _empty('Reading the conversation…');
    final queued = log.queued, live = _live.value;
    // Rows from the bottom up, so the list is anchored at the newest end and
    // never jumps as answers, tool rows and the working line come and go.
    final tail = <(Key, Widget)>[
      if (live.asking) (const ValueKey('ask'), ChatAsk(terms: widget.terms, tab: widget.tab, live: live)),
      if (live.status != null) (const ValueKey('working'), ChatWorking(_live, onStop: () => widget.terms.key(widget.tab, TerminalKey.escape))),
      for (final q in queued.reversed)
        (ValueKey('q:$q'), Padding(padding: const EdgeInsets.only(top: 10), child: ChatUser(q, queued: true, sending: log.sending(q)))),
    ];
    // The top row: reading back further, or the conversation's start.
    final top = log.hasOlder || (log.start == 0 && items.isNotEmpty);
    final n = tail.length + items.length + (top ? 1 : 0);
    const topKey = ValueKey('top');
    Key keyAt(int i) => i < tail.length
        ? tail[i].$1
        : i - tail.length < items.length
            ? ObjectKey(items[items.length - 1 - (i - tail.length)])
            : topKey;
    return Stack(children: [
      ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
        itemCount: n,
        // Keys keep each row's state (selection, an open tool card, the
        // spinner) with its row as rows are added below it.
        findChildIndexCallback: (key) {
          for (var i = 0; i < n; i++) {
            if (keyAt(i) == key) return i;
          }
          return null;
        },
        itemBuilder: (_, r) {
          if (r < tail.length) return KeyedSubtree(key: tail[r].$1, child: tail[r].$2);
          if (r - tail.length >= items.length) {
            if (log.hasOlder) scheduleMicrotask(_older); // shown: read the page before it
            return Padding(
              key: topKey,
              padding: const EdgeInsets.only(bottom: 14),
              child: Center(
                child: log.hasOlder
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: C.dim))
                    : const Text('Start of the conversation', style: TextStyle(color: C.dim, fontSize: 12)),
              ),
            );
          }
          final i = items.length - 1 - (r - tail.length);
          final e = items[i];
          final prev = i > 0 ? items[i - 1].kind : '';
          final gap = e.kind == 'tool' && prev == 'tool' ? 2.0 : 10.0;
          return Padding(
            key: ObjectKey(e),
            padding: EdgeInsets.only(top: i == 0 ? 0 : gap),
            child: switch (e.kind) {
              'user' => ChatUser(e.text),
              // The copy button closes a turn: the last answer before you speak again.
              'text' => ChatAnswer(e.text,
                  onToShell: widget.onToShell, last: i == items.length - 1 || items[i + 1].kind == 'user'),
              'tool' => ChatTool(e, onToShell: widget.onToShell, onToggle: () => setState(() => e.open = !e.open)),
              _ => ChatNote(e.text),
            },
          );
        },
      ),
      if (!_atBottom)
        Positioned(
          right: 12,
          bottom: 12,
          child: FloatingActionButton.small(
            heroTag: null,
            backgroundColor: C.raised,
            foregroundColor: C.text,
            onPressed: _toBottom,
            child: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
        ),
    ]);
  }

  Widget _empty(String s) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(s, textAlign: TextAlign.center, style: const TextStyle(color: C.dim, height: 1.5)),
        ),
      );
}
