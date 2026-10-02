// The chat's message widgets: your message, the formatted answer (markdown)
// and the code blocks in it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:uniai/app/theme.dart';

/// Your message; a queued one (typed while Claude works) is outlined and
/// labelled until Claude takes it in.
class ChatUser extends StatelessWidget {
  const ChatUser(this.text, {super.key, this.queued = false, this.sending = false});
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
MarkdownStyleSheet chatMarkdown(BuildContext context) {
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

class ChatAnswer extends StatelessWidget {
  const ChatAnswer(this.text, {super.key, this.onToShell, this.last = false});
  final String text;
  final ValueChanged<String>? onToShell;
  final bool last; // ends a turn: offer to copy it whole

  @override
  Widget build(BuildContext context) {
    final body = MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: chatMarkdown(context),
      builders: {'pre': ChatCodeBlock(onToShell)},
      onTapLink: (text, href, title) {
        if (href == null) return;
        Clipboard.setData(ClipboardData(text: href));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
      },
    );
    if (!last) return body;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      body,
      ChatCodeActions(text, copyTip: 'Copy the answer'),
    ]);
  }
}

/// A fenced code block in an answer: its language, copy, and put into the
/// shell pane (pasted, so nothing runs until you press Enter there).
class ChatCodeBlock extends MarkdownElementBuilder {
  ChatCodeBlock(this.onToShell);
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
        child: ChatCodeActions(code, label: lang, onToShell: onToShell),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: SelectableText(code, style: chatMarkdown(context).code!.copyWith(backgroundColor: Colors.transparent, color: const Color(0xFFC0CAF5))),
      ),
    ]);
  }
}

/// Copy, and (when given [onToShell]) put into the terminal.
class ChatCodeActions extends StatelessWidget {
  const ChatCodeActions(this.text, {super.key, this.label = '', this.onToShell, this.copyTip = 'Copy'});
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
