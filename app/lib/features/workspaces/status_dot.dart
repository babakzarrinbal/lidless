// The activity dot of a session or conversation (green working, blinking blue
// unread, white read, gray closed).
import 'package:flutter/material.dart';
import 'package:uniai/features/workspaces/seen_conversations.dart';
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/chat/claude.dart';
import 'package:uniai/app/theme.dart';

/// Green: working. Blinking blue: stopped or asks, not seen yet. White:
/// read. Gray: closed.
class StatusDot extends StatelessWidget {
  const StatusDot(this.activity, {super.key, this.size = 8, this.border});
  final Activity activity;
  final double size;

  /// The dot in a session or conversation row.
  static const double row = 12;
  final Color? border;

  static Color color(Activity a) => switch (a) {
        Activity.working => C.green,
        Activity.unread => C.accent,
        Activity.read => Colors.white,
        Activity.closed => C.dim,
      };

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color(activity),
        shape: BoxShape.circle,
        border: border == null ? null : Border.all(color: border!, width: 1.5),
      ),
    );
    return activity == Activity.unread ? _Blink(child: dot) : dot;
  }
}

/// A slow fade in and out.
class _Blink extends StatefulWidget {
  const _Blink({required this.child});
  final Widget child;

  @override
  State<_Blink> createState() => _BlinkState();
}

class _BlinkState extends State<_Blink> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  late final _fade = Tween(begin: 1.0, end: .2).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion (and tests, which wait for animations to end): steady.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _fade, child: widget.child);
}

/// A Mac conversation's dot. One open on the phone is its session's; one
/// open on the Mac is working while its transcript keeps changing.
Activity conversationActivity(Conversation c, SeenConversations seen, List<Session> sessions) {
  for (final s in sessions) {
    if (s.agent != null && s.agent!.id == c.term) return s.activity;
  }
  if (!c.running) return Activity.closed;
  if (DateTime.now().difference(c.mtime) < const Duration(seconds: 20)) return Activity.working;
  return seen.unread(c) ? Activity.unread : Activity.read;
}
