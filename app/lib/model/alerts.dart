// Notifies when a session needs the user: its agent finished or asks
// something, and the phone has not shown it. The text is the end of the
// agent's last answer (or its question).
import 'package:flutter/widgets.dart';

import '../net/link.dart';
import '../net/notify.dart';
import 'chat.dart';
import 'terms.dart';

class Alerts with WidgetsBindingObserver {
  Alerts(this.link, this.terms) {
    terms.onUnread = _unread;
    terms.onRead = (s) => Notify.cancel(notifyId(s));
    terms.addListener(_watch);
    WidgetsBinding.instance.addObserver(this);
  }

  final Link link;
  final Terms terms;
  String? _watching;

  /// One notification per session, replaced as it goes on.
  static int notifyId(String session) => session.hashCode & 0x7fffffff;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) terms.foreground = true;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) terms.foreground = false;
  }

  // While an agent works, the app away keeps the link up to tell when it stops.
  void _watch() {
    final n = terms.sessions.where((s) => s.activity == Activity.working).length;
    final text = n == 0 ? null : '${n == 1 ? 'An agent is' : '$n agents are'} working on ${link.host}';
    if (text == _watching) return;
    _watching = text;
    Notify.watch(text);
  }

  Future<void> _unread(TermTab t, LiveScreen live) async {
    final s = terms.session(t.session);
    if (s == null) return;
    final asks = live.asking;
    var text = asks
        ? [?live.question, for (final o in live.options) '${o.$1}. ${o.$2}'].join('\n')
        : await _lastAnswer(t);
    if (text.isEmpty) text = 'Finished. Tap to see.';
    // A message the user saw meanwhile needs no notification.
    if (!t.unread) return;
    Notify.show(
      notifyId(s.id),
      '${s.name} · ${asks ? '${s.toolName} asks' : '${s.toolName} is done'}',
      tail(text),
      '${link.pairing.room}|${s.id}',
    );
  }

  Future<String> _lastAnswer(TermTab t) async {
    if (t.kind == 'claude' || t.kind == 'copilot') {
      await t.chat.catchUp(link, t.id);
      for (final e in t.chat.items.reversed) {
        if (e.kind == 'text' && e.text.trim().isNotEmpty) return e.text.trim();
      }
    }
    // A plain terminal (or no transcript): its last lines.
    final b = t.terminal.buffer;
    final lines = <String>[];
    for (var i = b.height - 1; i >= 0 && lines.length < 6; i--) {
      final l = b.lines[i].getText().trimRight();
      if (l.isNotEmpty || lines.isNotEmpty) lines.insert(0, l);
    }
    return lines.join('\n').trim();
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    terms.removeListener(_watch);
    terms.onUnread = null;
    terms.onRead = null;
    if (_watching != null) Notify.watch(null);
  }
}

/// The last part of a long message, cut at a word.
String tail(String s, [int max = 400]) {
  final t = s.trim();
  if (t.length <= max) return t;
  var cut = t.substring(t.length - max);
  final sp = cut.indexOf(RegExp(r'\s'));
  if (sp > 0 && sp < 40) cut = cut.substring(sp + 1);
  return '…$cut';
}
