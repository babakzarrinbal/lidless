import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../model/chat.dart';
import '../model/terms.dart';
import 'theme.dart';

/// The agent's conversation the way the Claude app shows it: your messages,
/// formatted answers, and one compact row per tool call that opens to show
/// the command, the diff and the output. It follows the transcript Claude
/// Code writes on the Mac and polls whenever the terminal draws something.
class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.terms, required this.tab});
  final Terms terms;
  final TermTab tab;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scroll = ScrollController();
  Timer? _soon, _every;
  bool _atBottom = true;
  LiveScreen _live = const LiveScreen();

  ChatLog get log => widget.tab.chat;

  @override
  void initState() {
    super.initState();
    _attach();
    _scroll.addListener(() {
      final p = _scroll.position;
      final at = p.pixels >= p.maxScrollExtent - 80;
      if (at != _atBottom) setState(() => _atBottom = at);
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
    super.dispose();
  }

  void _poll() => log.poll(widget.terms.link, widget.tab.id);

  // The screen changes many times a second while Claude works: read the
  // transcript and the screen at most a few times a second.
  void _onScreen() {
    if (_soon?.isActive ?? false) return;
    _soon = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _poll();
      final live = LiveScreen.of(widget.tab.terminal);
      if (live.status != _live.status || live.question != _live.question || live.options.length != _live.options.length) {
        setState(() => _live = live);
        _follow();
      }
    });
  }

  void _onLog() {
    setState(() {});
    _follow();
  }

  void _follow() {
    if (!_atBottom) return;
    // Lazily built rows change the extent as they appear: settle twice.
    for (final d in [Duration.zero, const Duration(milliseconds: 80)]) {
      Future.delayed(d, () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      });
    }
  }

  void _toBottom() {
    setState(() => _atBottom = true);
    _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    _follow();
  }

  @override
  Widget build(BuildContext context) {
    final items = log.items;
    if (log.loaded && log.path.isEmpty) {
      return _empty('Nothing here yet: send Claude a message below.\nIts start-up screen (a folder trust question, say) is under Terminal at the top right.');
    }
    if (!log.loaded) return _empty('Reading the conversation…');
    final extra = (_live.status != null ? 1 : 0) + (_live.asking ? 1 : 0);
    return Stack(children: [
      ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
        itemCount: items.length + extra,
        itemBuilder: (_, i) {
          if (i >= items.length) {
            return i == items.length && _live.status != null ? _Working(_live.status!) : _Ask(terms: widget.terms, tab: widget.tab, live: _live);
          }
          final e = items[i];
          final prev = i > 0 ? items[i - 1].kind : '';
          final gap = e.kind == 'tool' && prev == 'tool' ? 2.0 : 10.0;
          return Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : gap),
            child: switch (e.kind) {
              'user' => _User(e.text),
              'text' => _Answer(e.text),
              'tool' => _Tool(e, onToggle: () => setState(() => e.open = !e.open)),
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

class _User extends StatelessWidget {
  const _User(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF223049),
            borderRadius: BorderRadius.circular(18).copyWith(bottomRight: const Radius.circular(6)),
          ),
          child: SelectableText(text, style: const TextStyle(fontSize: 15, height: 1.4, color: C.text)),
        ),
      );
}

MarkdownStyleSheet _md(BuildContext context) {
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
  const _Answer(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => MarkdownBody(
        data: text,
        selectable: true,
        styleSheet: _md(context),
        onTapLink: (text, href, title) {
          if (href == null) return;
          Clipboard.setData(ClipboardData(text: href));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
        },
      );
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
  const _Tool(this.e, {required this.onToggle});
  final ChatEntry e;
  final VoidCallback onToggle;

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
          if (e.detail.isNotEmpty) _Code(e.detail, diff: e.name.contains('Edit')),
          if (e.result?.isNotEmpty ?? false) _Code(e.result!, color: e.err ? C.red : null),
          const SizedBox(height: 6),
        ],
      ]),
    );
  }
}

class _Code extends StatelessWidget {
  const _Code(this.text, {this.diff = false, this.color});
  final String text;
  final bool diff;
  final Color? color;

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
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(10),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText.rich(span),
        ),
      ),
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

class _Working extends StatelessWidget {
  const _Working(this.status);
  final String status;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: C.amber)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(status,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: C.amber)),
          ),
        ]),
      );
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
