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
  late final Map<String, int> _seen = _loadSeen();

  String get _shutKey => 'foldersShut:${widget.mac}';
  String get _seenKey => 'convSeen:${widget.mac}';

  Map<String, int> _loadSeen() {
    try {
      return (jsonDecode(widget.prefs?.getString(_seenKey) ?? '{}') as Map).cast<String, int>();
    } catch (_) {
      return {};
    }
  }

  @override
  void initState() {
    super.initState();
    widget.dirs.forEach(_fetch);
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
      final open = _openTerms();
      for (final c in list) {
        // First seen, or open on the phone: read up to now.
        if (!_seen.containsKey(c.id) || open.contains(c.term)) _seen[c.id] = c.mtime.millisecondsSinceEpoch;
      }
      widget.prefs?.setString(_seenKey, jsonEncode(_seen));
      setState(() => _convs[dir] = list);
    } catch (_) {
      // an older agent, or the folder is gone: the open sessions still show
    }
  }

  Set<int> _openTerms() => {
        for (final s in widget.sessions)
          if (s.agent != null) s.agent!.id,
      };

  bool _unread(Conversation c) => c.mtime.millisecondsSinceEpoch > (_seen[c.id] ?? 0);

  void _toggle(String dir) {
    setState(() => _shut.contains(dir) ? _shut.remove(dir) : _shut.add(dir));
    widget.prefs?.setStringList(_shutKey, _shut.toList());
  }

  void _resume(String dir, Conversation c) {
    _seen[c.id] = c.mtime.millisecondsSinceEpoch;
    widget.prefs?.setString(_seenKey, jsonEncode(_seen));
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
        final unread = here.any((s) => s.agent?.unread ?? false) || convs.any(_unread);
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
            if (unread) const StatusDot(StatusDot.unread),
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
          if (!opened && old.any(_unread)) ...[const SizedBox(width: 8), const StatusDot(StatusDot.unread)],
        ]),
      ),
    );
  }

  Widget _convTile(String dir, Conversation c) => InkWell(
        onTap: () => _resume(dir, c), // offline, starting it says so
        child: Padding(
          padding: const EdgeInsets.fromLTRB(46, 7, 16, 7),
          child: Row(children: [
            StatusDot(_unread(c)
                ? StatusDot.unread
                : c.running
                    ? StatusDot.active
                    : StatusDot.idle),
            const SizedBox(width: 10),
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

/// Green: running. Blue: wrote something not seen yet. Gray: idle.
class StatusDot extends StatelessWidget {
  const StatusDot(this.color, {super.key, this.size = 8, this.border});
  final Color color;
  final double size;
  final Color? border;

  static const active = C.green, unread = C.accent, idle = C.dim;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: border == null ? null : Border.all(color: border!, width: 1.5),
        ),
      );
}
