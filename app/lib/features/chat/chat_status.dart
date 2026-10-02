// The chat's live parts: Claude's working line, and the choice it is waiting
// on (permission, plan approval).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/chat/chat.dart';
import 'package:uniai/features/terminals/terms.dart';
import 'package:uniai/app/theme.dart';

/// Claude's working line, the way the terminal shows it: a turning glyph and
/// its word ("Pondering…") with a light running over it, then time and tokens.
class ChatWorking extends StatefulWidget {
  const ChatWorking(this.live, {super.key, required this.onStop});
  final ValueListenable<LiveScreen> live;
  final VoidCallback onStop; // esc: Claude stops what it is doing

  @override
  State<ChatWorking> createState() => ChatWorkingState();
}

class ChatWorkingState extends State<ChatWorking> with SingleTickerProviderStateMixin {
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
class ChatAsk extends StatelessWidget {
  const ChatAsk({super.key, required this.terms, required this.tab, required this.live});
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
