// The recent page's list: the newest conversations of every folder (claude.recent).
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uniai/features/workspaces/workspaces.dart';
import 'package:uniai/features/workspaces/seen_conversations.dart';
import 'package:uniai/features/workspaces/status_dot.dart';
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/chat/claude.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/features/workspaces/new_session.dart';
import 'package:uniai/app/logos.dart';
import 'package:uniai/app/theme.dart';

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
      debugPrint('uniai: recent ${list.length} (epoch $epoch)');
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
      debugPrint('uniai: recent failed (epoch $epoch, try $_tries): $e');
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
    // Live terminals first; the rest newest first, older than today folded.
    final (active, rest) = Conversation.ordered(list, openTerms(widget.sessions));
    final midnight = DateUtils.dateOnly(DateTime.now());
    final today = rest.where((c) => !c.mtime.isBefore(midnight)).toList();
    final old = rest.where((c) => c.mtime.isBefore(midnight)).toList();
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
      for (final c in active) _tile(c),
      if (active.isNotEmpty && today.isNotEmpty) const Divider(height: 12),
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
          StatusDot(_activity(c), size: StatusDot.row),
          const SizedBox(width: 10),
          ToolLogo(c.tool, size: 17),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.title.isEmpty ? '(untitled)' : c.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
              const SizedBox(height: 2),
              Text(
                '${baseName(c.dir)}${open ? ' · open on the phone' : c.running ? ' · open on the Mac' : ''}',
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
