// Small chat-side widgets: context ring and conversation tiles.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:uniai/features/chat/chat.dart';
import 'package:uniai/features/chat/claude.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/app/theme.dart';

/// How full Claude's context window is: a ring with the token count inside.
class ContextRing extends StatelessWidget {
  const ContextRing(this.use, {super.key, this.size = 38});
  final ContextUse use;
  final double size;

  Color get _color => use.fraction >= 0.85
      ? C.red
      : use.fraction >= 0.6
          ? C.amber
          : C.accent;

  @override
  Widget build(BuildContext context) {
    final pct = (use.fraction * 100).round();
    return Tooltip(
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 4),
      message: '${tokenCount(use.tokens)} of ${tokenCount(use.size)} tokens ($pct%)'
          '${use.model.isEmpty ? '' : '\n${use.model}'}',
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingPainter(use.fraction, _color),
          child: Center(
            child: Text(tokenCount(use.tokens),
                style: TextStyle(fontSize: size * 0.26, fontWeight: FontWeight.w600, color: C.text, height: 1)),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, this.color);
  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 3.0;
    final r = Rect.fromLTWH(w / 2, w / 2, size.width - w, size.height - w);
    canvas.drawArc(r, 0, 2 * math.pi, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..color = C.line);
    if (fraction > 0) {
      canvas.drawArc(r, -math.pi / 2, 2 * math.pi * math.max(fraction, 0.02), false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round
        ..color = color);
    }
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.fraction != fraction || o.color != color;
}

/// The folder's Claude conversations, newest first; picks one.
Future<Conversation?> pickConversation(BuildContext context, Link link, String dir, {int? currentTerm}) =>
    showModalBottomSheet<Conversation>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.panel,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => FutureBuilder<List<Conversation>>(
          future: Conversation.list(link, dir),
          builder: (ctx, snap) {
            final head = Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Row(children: [
                const Icon(Icons.history_rounded, size: 18, color: C.dim),
                const SizedBox(width: 8),
                const Text('Conversations in this folder', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ]),
            );
            if (snap.hasError) {
              return ListView(controller: scroll, children: [
                head,
                Padding(padding: const EdgeInsets.all(18), child: Text('${snap.error}', style: const TextStyle(color: C.red))),
              ]);
            }
            final list = snap.data;
            if (list == null) {
              return ListView(controller: scroll, children: [
                head,
                const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
              ]);
            }
            return ListView.builder(
              controller: scroll,
              itemCount: list.length + 1,
              itemBuilder: (ctx, i) {
                if (i == 0) {
                  return list.isEmpty
                      ? Column(children: [
                          head,
                          const Padding(
                              padding: EdgeInsets.all(18),
                              child: Text('Claude has no conversations here yet.', style: TextStyle(color: C.dim))),
                        ])
                      : head;
                }
                final c = list[i - 1];
                return ConversationTile(c, current: currentTerm != null && c.term == currentTerm, onTap: () => Navigator.pop(ctx, c));
              },
            );
          },
        ),
      ),
    );

class ConversationTile extends StatelessWidget {
  const ConversationTile(this.c, {super.key, required this.current, required this.onTap});
  final Conversation c;
  final bool current; // the one this pane shows
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (badge, color) = current
        ? ('this one', C.green)
        : c.term != 0
            ? ('open here', C.accent)
            : c.running
                ? ('running on the Mac', C.amber)
                : ('', C.dim);
    return InkWell(
      onTap: current ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (c.running) ...[
              Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 7),
            ],
            Expanded(
              child: Text(c.title.isEmpty ? '(untitled)' : c.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            ),
            const SizedBox(width: 8),
            Text(agoText(c.mtime), style: const TextStyle(fontSize: 11.5, color: C.dim)),
          ]),
          if (c.prompt.isNotEmpty && c.prompt != c.title)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('› ${c.prompt}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: C.dim)),
            ),
          if (badge.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(badge, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
            ),
        ]),
      ),
    );
  }
}

/// The commands matching what is typed, above the message field.
class SlashList extends StatelessWidget {
  const SlashList({super.key, required this.commands, required this.onPick});
  final List<SlashCommand> commands;
  final ValueChanged<SlashCommand> onPick;

  @override
  Widget build(BuildContext context) => Material(
        color: C.raised,
        elevation: 8,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: C.line),
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.builder(
            shrinkWrap: true,
            reverse: true, // the best match sits next to the field
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: commands.length,
            itemBuilder: (ctx, i) {
              final c = commands[i];
              return InkWell(
                onTap: () => onPick(c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('/${c.name}', style: const TextStyle(fontFamily: mono, fontSize: 13.5, color: C.accent)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(c.desc, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: C.dim)),
                    ),
                    if (c.src != 'built-in')
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(c.src, style: const TextStyle(fontSize: 10.5, color: C.violet)),
                      ),
                  ]),
                ),
              );
            },
          ),
        ),
      );
}
