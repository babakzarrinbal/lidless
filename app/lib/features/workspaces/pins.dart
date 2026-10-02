// Pinned sessions: kept on top of the drawer and the Recent page. Each
// device pins its own, per Mac (prefs `pinned:<mac>`). See README.md.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/app/theme.dart';
import 'package:uniai/features/chat/claude.dart' show Conversation;
import 'package:uniai/features/terminals/session.dart';

/// A pin is an open session (`s:<session id>`) and, once known, its
/// conversation (`c:<conversation id>`). The conversation key is what lasts:
/// a closed session's pin goes with it, and resuming a pinned conversation
/// pins the new session.
class Pins extends ChangeNotifier {
  Pins(this.mac, {SharedPreferences? prefs}) {
    if (prefs != null) {
      _load(prefs);
    } else {
      SharedPreferences.getInstance().then(_load);
    }
  }

  final String mac;
  SharedPreferences? _prefs;
  final _keys = <String>{};

  String get _key => 'pinned:$mac';

  void _load(SharedPreferences p) {
    _prefs = p;
    _keys.addAll(p.getStringList(_key) ?? const []);
    notifyListeners();
  }

  void _save() {
    _prefs?.setStringList(_key, _keys.toList());
    notifyListeners();
  }

  bool session(Session s) => _keys.contains('s:${s.id}');

  /// [c] is pinned, or the open session that has it is.
  bool conversation(Conversation c, List<Session> open) {
    if (_keys.contains('c:${c.id}')) return true;
    final s = _sessionOf(c, open);
    return s != null && session(s);
  }

  /// Pins both, or unpins both when either is pinned.
  void toggle({Session? s, Conversation? c}) {
    final keys = [if (s != null) 's:${s.id}', if (c != null) 'c:${c.id}'];
    if (keys.any(_keys.contains)) {
      _keys.removeAll(keys);
    } else {
      _keys.addAll(keys);
    }
    _save();
  }

  /// A list of conversations came: the ones open in a pinned session are
  /// pinned too, so the pin outlasts the session.
  void learn(List<Conversation> list, List<Session> open) {
    final add = [
      for (final c in list)
        if (!_keys.contains('c:${c.id}') && conversation(c, open)) 'c:${c.id}',
    ];
    if (add.isEmpty) return;
    _keys.addAll(add);
    _save();
  }

  /// A pinned conversation was resumed in session [id].
  void resumed(Conversation c, String id) {
    if (_keys.contains('c:${c.id}') && _keys.add('s:$id')) _save();
  }

  /// Drops the pins of sessions no longer open (the Mac's list is in).
  void prune(List<Session> open) {
    final ids = {for (final s in open) 's:${s.id}'};
    final gone = [for (final k in _keys) if (k.startsWith('s:') && !ids.contains(k)) k];
    if (gone.isEmpty) return;
    _keys.removeAll(gone);
    _save();
  }

  static Session? _sessionOf(Conversation c, List<Session> open) =>
      c.term == 0 ? null : open.where((s) => s.agent?.id == c.term).firstOrNull;
}

/// The menu on a session or conversation (long press, or right click on a
/// Mac): Pin / Unpin, and Close for an open session. Returns 'pin' or 'close'.
Future<String?> pinMenu(BuildContext context, {required String title, required bool pinned, bool close = false}) {
  HapticFeedback.selectionClick();
  return showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
        ListTile(
          leading: Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded),
          title: Text(pinned ? 'Unpin' : 'Pin to the top'),
          subtitle: const Text('On this device'),
          onTap: () => Navigator.pop(ctx, 'pin'),
        ),
        if (close)
          ListTile(
            leading: const Icon(Icons.close_rounded),
            title: const Text('Close session'),
            onTap: () => Navigator.pop(ctx, 'close'),
          ),
      ]),
    ),
  );
}

/// The small pin shown on a pinned row.
const pinMark = Padding(
  padding: EdgeInsets.only(left: 6),
  child: Icon(Icons.push_pin_rounded, size: 13, color: C.dim),
);
