import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/claude.dart';
import '../model/terms.dart';
import '../net/link.dart';
import 'new_session.dart';
import 'theme.dart';

/// The drawer's sessions by folder: the ones open on the phone, then Claude's
/// other conversations there. Today's show; older ones fold under
/// "Old sessions".
class WorkspaceList extends StatefulWidget {
  const WorkspaceList({
    super.key,
    required this.link,
    required this.prefs,
    required this.mac,
    required this.sessions,
    required this.dirs,
    required this.tile,
    required this.onNew,
    required this.onResume,
    this.load,
  });
  final Link link;
  final SharedPreferences? prefs;
  final String mac;
  final List<Session> sessions;
  final List<String> dirs; // the open sessions' folders first, then recent ones
  final Widget Function(Session) tile;
  final void Function(String dir) onNew;
  final void Function(String dir, Conversation c) onResume;
  final Future<List<Conversation>> Function(String dir)? load; // tests: instead of asking the Mac

  @override
  State<WorkspaceList> createState() => _WorkspaceListState();
}

class _WorkspaceListState extends State<WorkspaceList> {
  final _convs = <String, List<Conversation>>{};
  final _oldOpen = <String>{};
  late final Set<String> _shut = {...?widget.prefs?.getStringList(_shutKey)};
  late final _seen = SeenConversations(widget.prefs, widget.mac);

  String get _shutKey => 'foldersShut:${widget.mac}';

  @override
  void initState() {
    super.initState();
    widget.link.addListener(_online);
    widget.dirs.forEach(_fetch);
  }

  @override
  void dispose() {
    widget.link.removeListener(_online);
    _retry?.cancel();
    super.dispose();
  }

  Timer? _retry;

  // Started (or switched to) before the Mac answered: ask once it does, and
  // again shortly for any folder whose answer didn't come.
  void _online() {
    if (!widget.link.online) return;
    for (final d in widget.dirs) {
      if (!_convs.containsKey(d)) _fetch(d);
    }
  }

  @override
  void didUpdateWidget(WorkspaceList old) {
    super.didUpdateWidget(old);
    for (final d in widget.dirs) {
      if (!old.dirs.contains(d)) _fetch(d);
    }
  }

  Future<void> _fetch(String dir) async {
    final load = widget.load;
    if (load == null && !widget.link.online) return;
    try {
      final list = await (load ?? (d) => Conversation.list(widget.link, d))(dir);
      if (!mounted) return;
      _seen.listed(list, _openTerms());
      setState(() => _convs[dir] = list);
    } catch (_) {
      // An older agent, the folder is gone, or the link just came up: the
      // open sessions still show; try once more in a moment.
      if (!mounted || widget.load != null || (_retry?.isActive ?? false)) return;
      _retry = Timer(const Duration(seconds: 3), _online);
    }
  }

  Set<int> _openTerms() => openTerms(widget.sessions);

  Activity _activity(Conversation c) => conversationActivity(c, _seen, widget.sessions);

  void _toggle(String dir) {
    setState(() => _shut.contains(dir) ? _shut.remove(dir) : _shut.add(dir));
    widget.prefs?.setStringList(_shutKey, _shut.toList());
  }

  void _resume(String dir, Conversation c) {
    _seen.read(c);
    widget.onResume(dir, c);
  }

  @override
  Widget build(BuildContext context) {
    final open = _openTerms();
    final midnight = DateUtils.dateOnly(DateTime.now());
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final dir in widget.dirs) ...() {
        final here = widget.sessions.where((s) => s.dir == dir).toList();
        final convs = [for (final c in _convs[dir] ?? const <Conversation>[]) if (!open.contains(c.term)) c];
        final today = convs.where((c) => !c.mtime.isBefore(midnight)).toList();
        final old = convs.where((c) => c.mtime.isBefore(midnight)).toList();
        final shut = _shut.contains(dir);
        final unread = here.any((s) => s.activity == Activity.unread) ||
            convs.any((c) => _activity(c) == Activity.unread);
        return [
          _header(dir, shut: shut, count: here.length + today.length, unread: shut && unread),
          if (!shut) ...[
            for (final s in here) widget.tile(s),
            for (final c in today) _convTile(dir, c),
            if (old.isNotEmpty) ...[
              _oldRow(dir, old),
              if (_oldOpen.contains(dir))
                for (final c in old) _convTile(dir, c),
            ],
          ],
        ];
      }(),
    ]);
  }

  Widget _header(String dir, {required bool shut, required int count, required bool unread}) => InkWell(
        onTap: () => _toggle(dir),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 4, 2),
          child: Row(children: [
            Icon(shut ? Icons.chevron_right_rounded : Icons.expand_more_rounded, size: 18, color: C.dim),
            const SizedBox(width: 4),
            const Icon(Icons.folder_rounded, size: 18, color: C.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(baseName(dir), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                Text(tildePath(dir, widget.link.home),
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: C.dim)),
              ]),
            ),
            if (unread) const StatusDot(Activity.unread),
            if (shut && count > 0)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text('$count', style: const TextStyle(fontSize: 12, color: C.dim)),
              ),
            IconButton(
              tooltip: 'New session here',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_rounded, size: 19, color: C.dim),
              onPressed: widget.link.online ? () => widget.onNew(dir) : null,
            ),
          ]),
        ),
      );

  Widget _oldRow(String dir, List<Conversation> old) {
    final opened = _oldOpen.contains(dir);
    return InkWell(
      onTap: () => setState(() => opened ? _oldOpen.remove(dir) : _oldOpen.add(dir)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(44, 7, 16, 7),
        child: Row(children: [
          Icon(opened ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 16, color: C.dim),
          const SizedBox(width: 6),
          Text('Old sessions (${old.length})', style: const TextStyle(fontSize: 12.5, color: C.dim)),
          if (!opened && old.any((c) => _activity(c) == Activity.unread)) ...[
            const SizedBox(width: 8),
            const StatusDot(Activity.unread),
          ],
        ]),
      ),
    );
  }

  Widget _convTile(String dir, Conversation c) => InkWell(
        onTap: () => _resume(dir, c), // offline, starting it says so
        child: Padding(
          padding: const EdgeInsets.fromLTRB(46, 7, 16, 7),
          child: Row(children: [
            StatusDot(_activity(c)),
            const SizedBox(width: 10),
            Icon(toolIcon(c.tool), size: 14, color: C.dim),
            const SizedBox(width: 6),
            Expanded(
              child: Text(c.title.isEmpty ? '(untitled)' : c.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
            ),
            const SizedBox(width: 8),
            Text(agoText(c.mtime), style: const TextStyle(fontSize: 11, color: C.dim)),
          ]),
        ),
      );
}

Set<int> openTerms(List<Session> sessions) => {
      for (final s in sessions)
        if (s.agent != null) s.agent!.id,
    };

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

/// The newest conversations of every folder on the Mac, to pick one up:
/// today's, then older ones folded under "Old sessions".
class RecentList extends StatefulWidget {
  const RecentList({
    super.key,
    required this.link,
    required this.prefs,
    required this.mac,
    required this.sessions,
    required this.onResume,
    this.load,
  });
  final Link link;
  final SharedPreferences? prefs;
  final String mac;
  final List<Session> sessions;
  final void Function(String dir, Conversation c) onResume;
  final Future<List<Conversation>> Function()? load; // tests: instead of asking the Mac

  @override
  State<RecentList> createState() => _RecentListState();
}

class _RecentListState extends State<RecentList> {
  List<Conversation>? _list;
  bool _old = false, _busy = false;
  late final _seen = SeenConversations(widget.prefs, widget.mac);
  Timer? _tick;

  Activity _activity(Conversation c) => conversationActivity(c, _seen, widget.sessions);

  @override
  void initState() {
    super.initState();
    widget.link.addListener(_online);
    _fetch();
    // The Mac's conversations move on: keep their dots current.
    if (widget.load == null) {
      _tick = Timer.periodic(const Duration(seconds: 15), (_) {
        if (widget.link.online && !_busy) _fetch();
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.link.removeListener(_online);
    super.dispose();
  }

  bool _failed = false;
  int _tries = 0, _epoch = -1; // _epoch: the connection the list came over
  String? _error; // why the last fetch failed, shown with a retry

  // A reconnect (the app was away, the network changed) may have lost the
  // question: ask again on every new connection until one answers.
  void _online() {
    if (!widget.link.online) return;
    if (_list == null || _failed || _epoch != widget.link.epoch) _fetch();
  }

  Future<void> _fetch() async {
    final load = widget.load;
    if (_busy || (load == null && !widget.link.online)) return;
    _busy = true;
    final epoch = widget.link.epoch;
    if (mounted && _list != null) setState(() {}); // the refresh button spins
    try {
      final list = await (load ?? () => Conversation.recent(widget.link))();
      if (!mounted) return;
      debugPrint('lidless: recent ${list.length} (epoch $epoch)');
      _seen.listed(list, openTerms(widget.sessions));
      _failed = false;
      _tries = 0;
      _epoch = epoch;
      setState(() {
        _list = list;
        _error = null;
      });
    } catch (e) {
      // An older agent, or the link just came up: say why, ask again a few times.
      debugPrint('lidless: recent failed (epoch $epoch, try $_tries): $e');
      _failed = true;
      if (mounted) {
        setState(() {
          _list ??= const [];
          _error = e is RpcError ? e.message : '$e';
        });
      }
      if (mounted && widget.load == null && ++_tries < 5) Timer(const Duration(seconds: 3), _online);
    } finally {
      _busy = false;
      // The connection changed while asking: the answer may never come.
      if (mounted && widget.link.online && widget.link.epoch != epoch) scheduleMicrotask(_online);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    if (list == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 10),
          Flexible(child: Text('Asking the Mac for recent sessions…', style: TextStyle(color: C.dim))),
        ]),
      );
    }
    final midnight = DateUtils.dateOnly(DateTime.now());
    final today = list.where((c) => !c.mtime.isBefore(midnight)).toList();
    final old = list.where((c) => c.mtime.isBefore(midnight)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(child: Text('Recent sessions', style: TextStyle(color: C.dim, fontSize: 13))),
        IconButton(
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
          icon: _busy
              ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh_rounded, size: 19, color: C.dim),
          onPressed: _fetch,
        ),
      ]),
      if (_error != null)
        Text('Couldn\'t load them: $_error', style: const TextStyle(color: C.red))
      else if (list.isEmpty)
        const Text('No conversations in the shared folders yet.', style: TextStyle(color: C.dim)),
      for (final c in today) _tile(c),
      if (old.isNotEmpty) ...[
        InkWell(
          onTap: () => setState(() => _old = !_old),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(children: [
              Icon(_old ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 16, color: C.dim),
              const SizedBox(width: 6),
              Text('Old sessions (${old.length})', style: const TextStyle(fontSize: 12.5, color: C.dim)),
              if (!_old && old.any((c) => _activity(c) == Activity.unread)) ...[
                const SizedBox(width: 8),
                const StatusDot(Activity.unread),
              ],
            ]),
          ),
        ),
        if (_old)
          for (final c in old) _tile(c),
      ],
    ]);
  }

  Widget _tile(Conversation c) {
    final open = openTerms(widget.sessions).contains(c.term);
    return InkWell(
      onTap: () {
        _seen.read(c);
        widget.onResume(c.dir, c);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          StatusDot(_activity(c)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.title.isEmpty ? '(untitled)' : c.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
              const SizedBox(height: 2),
              Text(
                '${tools[c.tool] ?? c.tool} · ${baseName(c.dir)}${open ? ' · open on the phone' : c.running ? ' · open on the Mac' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: C.dim),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Text(agoText(c.mtime), style: const TextStyle(fontSize: 11.5, color: C.dim)),
        ]),
      ),
    );
  }
}

/// Green: working. Blinking blue: stopped or asks, not seen yet. White:
/// read. Gray: closed.
class StatusDot extends StatelessWidget {
  const StatusDot(this.activity, {super.key, this.size = 8, this.border});
  final Activity activity;
  final double size;
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
