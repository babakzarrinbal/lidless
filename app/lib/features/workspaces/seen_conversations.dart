// Which of the Mac's conversations the phone has shown, so the lists can
// mark the ones that wrote something since.
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uniai/features/chat/claude.dart';

/// Which conversations wrote something since the phone last showed them, per
/// Mac: {id: mtime ms read up to}.
class SeenConversations {
  /// One per Mac, so every list (and Home) shares what was read.
  factory SeenConversations(SharedPreferences? prefs, String mac) {
    if (prefs == null) return SeenConversations._(null, mac);
    final had = _all[mac];
    if (had != null && identical(had.prefs, prefs)) return had;
    return _all[mac] = SeenConversations._(prefs, mac);
  }
  SeenConversations._(this.prefs, String mac) : _key = 'convSeen:$mac' {
    try {
      _seen.addAll((jsonDecode(prefs?.getString(_key) ?? '{}') as Map).cast<String, int>());
    } catch (_) {}
  }
  static final _all = <String, SeenConversations>{};
  final SharedPreferences? prefs;
  final String _key;
  final _seen = <String, int>{};

  bool unread(Conversation c) => c.mtime.millisecondsSinceEpoch > (_seen[c.id] ?? 0);

  /// The Mac listed these: the ones first seen, or open on the phone, are
  /// read up to now.
  void listed(List<Conversation> list, Set<int> open) {
    for (final c in list) {
      if (!_seen.containsKey(c.id) || open.contains(c.term)) _seen[c.id] = c.mtime.millisecondsSinceEpoch;
    }
    _save();
  }

  void read(Conversation c) {
    _seen[c.id] = c.mtime.millisecondsSinceEpoch;
    _save();
  }

  /// Read up to now: a conversation closed or left on the phone, after its
  /// last answer was on screen. Claude writes once more as it quits.
  void readNow(String id) {
    _seen[id] = DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch;
    _save();
  }

  void _save() => prefs?.setString(_key, jsonEncode(_seen));
}
