import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:xterm/xterm.dart' show TerminalKey;

import '../model/chat.dart';
import '../model/terms.dart';
import '../net/link.dart';
import 'new_session.dart' show baseName;
import 'theme.dart';

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
      if (live.asking) (const ValueKey('ask'), _Ask(terms: widget.terms, tab: widget.tab, live: live)),
      if (live.status != null) (const ValueKey('working'), _Working(_live, onStop: () => widget.terms.key(widget.tab, TerminalKey.escape))),
      for (final q in queued.reversed)
        (ValueKey('q:$q'), Padding(padding: const EdgeInsets.only(top: 10), child: _User(q, queued: true, sending: log.sending(q)))),
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
              'user' => _User(e.text),
              // The copy button closes a turn: the last answer before you speak again.
              'text' => _Answer(e.text,
                  onToShell: widget.onToShell, last: i == items.length - 1 || items[i + 1].kind == 'user'),
              'tool' => _Tool(e, onToShell: widget.onToShell, onToggle: () => setState(() => e.open = !e.open)),
              _ => _Note(e.text),
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

/// A VS Code Copilot Chat on the Mac. Only VS Code can add to it, so the
/// phone reads it (again every few seconds while open; the Mac answers "same"
/// when nothing changed) and offers to carry it on in a shared terminal,
/// where every device and the Mac follow it like any session.
class TranscriptPage extends StatefulWidget {
  const TranscriptPage(
      {super.key, required this.link, required this.id, required this.title, required this.dir, this.onContinue});
  final Link link;
  final String id, title, dir;
  final Future<bool> Function(String tool)? onContinue; // started: true

  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  final _scroll = ScrollController();
  Timer? _every;
  var _items = <ChatEntry>[];
  int _size = 0, _mtime = 0;
  bool _busy = false, _loaded = false, _starting = false;
  String? _error;

  /// Picks the agent, then hands the chat to it in a shared terminal.
  Future<void> _continue() async {
    final tool = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(
                'VS Code\'s chat can only grow inside VS Code. This starts a session in a shared terminal that reads '
                'the chat so far and carries on: every phone and the Mac (macremote attach) see it live.',
                style: TextStyle(color: C.dim, height: 1.4)),
          ),
          for (final t in const ['copilot', 'claude'])
            ListTile(
              leading: Icon(toolIcon(t)),
              title: Text('Continue with ${tools[t]}'),
              onTap: () => Navigator.pop(ctx, t),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (tool == null || !mounted) return;
    setState(() => _starting = true);
    final ok = await widget.onContinue!(tool);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _starting = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _read();
    _every = Timer.periodic(const Duration(seconds: 3), (_) => _read());
  }

  @override
  void dispose() {
    _every?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    if (_busy || !widget.link.online) return;
    _busy = true;
    try {
      final r = await widget.link.call('chat.transcript', {'session': widget.id, 'size': _size, 'mtime': _mtime});
      if (!mounted || r is! Map || r['same'] == true) return;
      // Read whole each time: keep the tool cards that were open.
      final open = {for (final e in _items) if (e.open) e.id};
      final items = <ChatEntry>[], tools = <String, ChatEntry>{};
      for (final m in (r['items'] as List? ?? const []).cast<Map>()) {
        if (m['k'] == 'result') {
          tools[m['id']]
            ?..result = m['text'] as String? ?? ''
            ..err = m['err'] == true;
          continue;
        }
        final e = ChatEntry.from(m);
        if (e.kind == 'tool') {
          tools[e.id] = e;
          e.open = open.contains(e.id);
        }
        items.add(e);
      }
      setState(() {
        _items = items;
        _size = ((r['size'] as num?) ?? 0).toInt();
        _mtime = ((r['mtime'] as num?) ?? 0).toInt();
        _loaded = true;
        _error = null;
      });
    } on RpcError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.code == 'unknown' ? 'This Mac\'s agent is too old to show VS Code chats: update it.' : e.message);
      if (!_loaded) _every?.cancel();
    } catch (_) {
      // The Mac went away for a moment: the next read tries again.
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
          Text('VS Code · ${baseName(widget.dir)}', style: const TextStyle(fontSize: 12, color: C.dim)),
        ]),
      ),
      bottomNavigationBar: widget.onContinue == null || !_loaded
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                child: FilledButton.icon(
                  onPressed: _starting ? null : _continue,
                  icon: _starting
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.devices_rounded),
                  label: const Text('Continue on all devices'),
                ),
              ),
            ),
      body: !_loaded
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error ?? 'Reading the conversation…',
                    textAlign: TextAlign.center, style: const TextStyle(color: C.dim, height: 1.5)),
              ),
            )
          : ListView.builder(
              controller: _scroll,
              reverse: true,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
              itemCount: items.length,
              itemBuilder: (_, r) {
                final i = items.length - 1 - r, e = items[i];
                final prev = i > 0 ? items[i - 1].kind : '';
                return Padding(
                  key: ObjectKey(e),
                  padding: EdgeInsets.only(top: i == 0 ? 0 : e.kind == 'tool' && prev == 'tool' ? 2.0 : 10.0),
                  child: switch (e.kind) {
                    'user' => _User(e.text),
                    'text' => _Answer(e.text, last: i == items.length - 1 || items[i + 1].kind == 'user'),
                    'tool' => _Tool(e, onToggle: () => setState(() => e.open = !e.open)),
                    _ => _Note(e.text),
                  },
                );
              },
            ),
    );
  }
}

/// Your message; a queued one (typed while Claude works) is outlined and
/// labelled until Claude takes it in.
class _User extends StatelessWidget {
  const _User(this.text, {this.queued = false, this.sending = false});
  final String text;
  final bool queued, sending;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: queued ? C.bg : const Color(0xFF223049),
              border: queued ? Border.all(color: const Color(0xFF223049), width: 1.5) : null,
              borderRadius: BorderRadius.circular(18).copyWith(bottomRight: const Radius.circular(6)),
            ),
            child: SelectableText(text,
                style: TextStyle(fontSize: 15, height: 1.4, color: queued ? C.dim : C.text)),
          ),
          if (queued)
            Padding(
              padding: const EdgeInsets.only(top: 3, right: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(sending ? Icons.arrow_upward_rounded : Icons.schedule_rounded, size: 12, color: C.dim),
                const SizedBox(width: 4),
                Text(sending ? 'Sending…' : 'Queued', style: const TextStyle(fontSize: 11.5, color: C.dim)),
              ]),
            ),
        ]),
      );
}

MarkdownStyleSheet? _mdSheet;
ThemeData? _mdTheme;

// One sheet per theme: a new sheet makes every answer parse its markdown again.
MarkdownStyleSheet _md(BuildContext context) {
  final theme = Theme.of(context);
  if (_mdSheet != null && identical(theme, _mdTheme)) return _mdSheet!;
  _mdTheme = theme;
  return _mdSheet = _mdBuild(context);
}

MarkdownStyleSheet _mdBuild(BuildContext context) {
  const body = TextStyle(fontSize: 15, height: 1.5, color: C.text);
  const code = TextStyle(fontFamily: mono, fontSize: 12.5, height: 1.45, color: Color(0xFFC0CAF5));
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: body,
    listBullet: body,
    strong: const TextStyle(fontWeight: FontWeight.w700),
    h1: body.copyWith(fontSize: 20, fontWeight: FontWeight.w700, height: 1.3),
    h2: body.copyWith(fontSize: 18, fontWeight: FontWeight.w700, height: 1.3),
    h3: body.copyWith(fontSize: 16, fontWeight: FontWeight.w700, height: 1.3),
    h4: body.copyWith(fontWeight: FontWeight.w700),
    pPadding: const EdgeInsets.only(bottom: 2),
    blockSpacing: 10,
    code: code.copyWith(backgroundColor: C.raised, color: C.cyan),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: const Color(0xFF0A0E14),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: C.line),
    ),
    blockquote: body.copyWith(color: C.dim),
    blockquoteDecoration: const BoxDecoration(border: Border(left: BorderSide(color: C.line, width: 3))),
    blockquotePadding: const EdgeInsets.only(left: 12),
    a: const TextStyle(color: C.accent),
    tableHead: body.copyWith(fontWeight: FontWeight.w700, fontSize: 14),
    tableBody: body.copyWith(fontSize: 14),
    tableBorder: TableBorder.all(color: C.line),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    // Tables are wider than a phone: intrinsic widths scroll sideways.
    tableColumnWidth: const IntrinsicColumnWidth(),
    horizontalRuleDecoration: const BoxDecoration(border: Border(top: BorderSide(color: C.line))),
  );
}

class _Answer extends StatelessWidget {
  const _Answer(this.text, {this.onToShell, this.last = false});
  final String text;
  final ValueChanged<String>? onToShell;
  final bool last; // ends a turn: offer to copy it whole

  @override
  Widget build(BuildContext context) {
    final body = MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: _md(context),
      builders: {'pre': _CodeBlock(onToShell)},
      onTapLink: (text, href, title) {
        if (href == null) return;
        Clipboard.setData(ClipboardData(text: href));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
      },
    );
    if (!last) return body;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      body,
      _CodeActions(text, copyTip: 'Copy the answer'),
    ]);
  }
}

/// A fenced code block in an answer: its language, copy, and put into the
/// shell pane (pasted, so nothing runs until you press Enter there).
class _CodeBlock extends MarkdownElementBuilder {
  _CodeBlock(this.onToShell);
  final ValueChanged<String>? onToShell;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
      BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    final first = element.children?.firstOrNull;
    final lang = first is md.Element ? (first.attributes['class'] ?? '').replaceFirst('language-', '') : '';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.only(left: 12),
        child: _CodeActions(code, label: lang, onToShell: onToShell),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: SelectableText(code, style: _md(context).code!.copyWith(backgroundColor: Colors.transparent, color: const Color(0xFFC0CAF5))),
      ),
    ]);
  }
}

/// Copy, and (when given [onToShell]) put into the terminal.
class _CodeActions extends StatelessWidget {
  const _CodeActions(this.text, {this.label = '', this.onToShell, this.copyTip = 'Copy'});
  final String text, label, copyTip;
  final ValueChanged<String>? onToShell;

  @override
  Widget build(BuildContext context) {
    Widget act(IconData icon, String tip, VoidCallback onTap) => IconButton(
          icon: Icon(icon, size: 17),
          tooltip: tip,
          color: C.dim,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
        );
    return Row(children: [
      Expanded(child: Text(label, style: const TextStyle(fontFamily: mono, fontSize: 11.5, color: C.dim))),
      act(Icons.copy_rounded, copyTip, () {
        Clipboard.setData(ClipboardData(text: text));
        toast(context, 'Copied');
      }),
      if (onToShell case final put?)
        act(Icons.terminal_rounded, 'Put into the terminal', () {
          put(text);
          toast(context, 'In the terminal: check it, then press Enter');
        }),
    ]);
  }
}

const _toolIcons = {
  'Bash': Icons.terminal_rounded,
  'Read': Icons.description_outlined,
  'Write': Icons.note_add_outlined,
  'Edit': Icons.edit_outlined,
  'MultiEdit': Icons.edit_outlined,
  'NotebookEdit': Icons.edit_outlined,
  'Grep': Icons.search_rounded,
  'Glob': Icons.folder_open_outlined,
  'WebFetch': Icons.public_rounded,
  'WebSearch': Icons.travel_explore_rounded,
  'Task': Icons.account_tree_outlined,
  'Agent': Icons.account_tree_outlined,
  'TodoWrite': Icons.checklist_rounded,
};

class _Tool extends StatelessWidget {
  const _Tool(this.e, {required this.onToggle, this.onToShell});
  final ChatEntry e;
  final VoidCallback onToggle;
  final ValueChanged<String>? onToShell;

  @override
  Widget build(BuildContext context) {
    final done = e.result != null;
    final Widget state = !done
        ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: C.amber))
        : Icon(e.err ? Icons.close_rounded : Icons.check_rounded, size: 14, color: e.err ? C.red : C.green);
    final hasMore = e.detail.isNotEmpty || (e.result?.isNotEmpty ?? false);
    return Container(
      decoration: BoxDecoration(
        color: e.open ? C.panel : null,
        borderRadius: BorderRadius.circular(10),
        border: e.open ? Border.all(color: C.line) : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: hasMore ? onToggle : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(children: [
              SizedBox(width: 16, child: Center(child: state)),
              const SizedBox(width: 8),
              Icon(_toolIcons[e.name] ?? Icons.extension_outlined, size: 16, color: C.violet),
              const SizedBox(width: 6),
              Text(e.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: C.text)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(e.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: mono, fontSize: 12, color: C.dim)),
              ),
              if (hasMore)
                Icon(e.open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: C.dim),
            ]),
          ),
        ),
        if (e.open) ...[
          if (e.detail.isNotEmpty)
            _Code(e.detail, diff: e.name.contains('Edit'), onToShell: e.name == 'Bash' ? onToShell : null),
          if (e.result?.isNotEmpty ?? false) _Code(e.result!, color: e.err ? C.red : null),
          const SizedBox(height: 6),
        ],
      ]),
    );
  }
}

class _Code extends StatelessWidget {
  const _Code(this.text, {this.diff = false, this.color, this.onToShell});
  final String text;
  final bool diff;
  final Color? color;
  final ValueChanged<String>? onToShell; // a command: offer to put it into the terminal

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontFamily: mono, fontSize: 12, height: 1.45, color: C.text);
    final lines = text.split('\n');
    final span = TextSpan(style: style.copyWith(color: color), children: [
      for (var i = 0; i < lines.length; i++)
        TextSpan(
          text: i < lines.length - 1 ? '${lines[i]}\n' : lines[i],
          style: !diff
              ? null
              : lines[i].startsWith('+ ')
                  ? const TextStyle(color: C.green, backgroundColor: Color(0x229ECE6A))
                  : lines[i].startsWith('- ')
                      ? const TextStyle(color: C.red, backgroundColor: Color(0x22F7768E))
                      : null,
        ),
    ]);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 8, 4),
      constraints: const BoxConstraints(maxHeight: 360),
      decoration: BoxDecoration(color: const Color(0xFF0A0E14), borderRadius: BorderRadius.circular(8)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _CodeActions(text, onToShell: onToShell),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText.rich(span),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          const Expanded(child: Divider()),
          Flexible(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(text,
                  textAlign: TextAlign.center,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: mono, fontSize: 11.5, color: C.dim)),
            ),
          ),
          const Expanded(child: Divider()),
        ]),
      );
}

/// Claude's working line, the way the terminal shows it: a turning glyph and
/// its word ("Pondering…") with a light running over it, then time and tokens.
class _Working extends StatefulWidget {
  const _Working(this.live, {required this.onStop});
  final ValueListenable<LiveScreen> live;
  final VoidCallback onStop; // esc: Claude stops what it is doing

  @override
  State<_Working> createState() => _WorkingState();
}

class _WorkingState extends State<_Working> with SingleTickerProviderStateMixin {
  static const _glyphs = ['·', '✢', '✳', '✶', '✻', '✽', '✻', '✶', '✳', '✢'];
  late final _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: AnimatedBuilder(
        animation: Listenable.merge([_spin, widget.live]),
        builder: (context, _) {
          final (word, meta) = workingParts(widget.live.value.status ?? '');
          final v = _spin.value;
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 18,
              child: Text(_glyphs[(v * _glyphs.length).floor() % _glyphs.length],
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, height: 1.1, color: C.amber)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (r) => LinearGradient(
                        colors: [C.amber, Color.lerp(C.amber, Colors.white, 0.75)!, C.amber],
                        stops: const [0.0, 0.5, 1.0],
                        begin: Alignment(-3 + v * 6 - 0.6, 0),
                        end: Alignment(-3 + v * 6 + 0.6, 0),
                      ).createShader(r),
                      child: Text(word.isEmpty ? 'Working…' : word,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: C.amber)),
                    ),
                  ),
                  if (meta.isNotEmpty)
                    TextSpan(text: '  $meta', style: const TextStyle(fontSize: 12, color: C.dim)),
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: C.dim,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () {
                HapticFeedback.lightImpact();
                widget.onStop();
              },
              icon: const Icon(Icons.stop_circle_outlined, size: 17),
              label: const Text('Stop', style: TextStyle(fontSize: 12.5)),
            ),
          ]);
        },
      ),
    );
  }
}

/// A choice Claude is waiting on (a permission, a plan approval…), with one
/// button per option; tapping types its number into the terminal.
class _Ask extends StatelessWidget {
  const _Ask({required this.terms, required this.tab, required this.live});
  final Terms terms;
  final TermTab tab;
  final LiveScreen live;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        decoration: BoxDecoration(
          color: C.panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.amber.withValues(alpha: 0.6)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(live.question ?? 'Claude is asking', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final (key, label) in live.options)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  side: const BorderSide(color: C.line),
                ),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  terms.type(tab, key);
                },
                child: Text('$key.  $label', style: const TextStyle(color: C.text)),
              ),
            ),
        ]),
      );
}
