// The workspace list: folders on the Mac with their conversations.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/chat/claude.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/features/workspaces/folder_menu.dart';
import 'package:uniai/features/workspaces/new_session.dart';
import 'package:uniai/app/logos.dart';
import 'package:uniai/app/theme.dart';
import 'package:uniai/features/workspaces/pins.dart';
import 'package:uniai/features/workspaces/seen_conversations.dart';
import 'package:uniai/features/workspaces/status_dot.dart';

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
    required this.pins,
    required this.dirs,
    required this.tile,
    required this.onNew,
    required this.onResume,
    this.onRemove,
    this.load,
  });
  final Link link;
  final SharedPreferences? prefs;
  final String mac;
  final List<Session> sessions;
  final Pins pins; // pinned sessions show above the folders; pinned conversations first in theirs
  final List<String> dirs; // the open sessions' folders first, then recent ones
  final Widget Function(Session) tile;
  final void Function(String dir) onNew;
  final void Function(String dir, Conversation c) onResume;
  final void Function(String dir)? onRemove; // took it off the recent folders
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
      widget.pins.learn(list, widget.sessions);
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
        final pins = widget.pins;
        final convs = [for (final c in _convs[dir] ?? const <Conversation>[]) if (!open.contains(c.term)) c];
        final pinned = convs.where((c) => pins.conversation(c, widget.sessions)).toList();
        convs.removeWhere(pinned.contains);
        final today = convs.where((c) => !c.mtime.isBefore(midnight)).toList();
        final old = convs.where((c) => c.mtime.isBefore(midnight)).toList();
        final shut = _shut.contains(dir);
        final unread = here.any((s) => s.activity == Activity.unread) ||
            convs.any((c) => _activity(c) == Activity.unread);
        return [
          _header(dir, shut: shut, count: here.length + pinned.length + today.length, unread: shut && unread, open: here.length),
          if (!shut) ...[
            for (final s in here.where((s) => !pins.session(s))) widget.tile(s),
            for (final c in pinned) _convTile(dir, c),
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

  Future<void> _menu(String dir, int open) async {
    if (await folderMenu(context, dir, home: widget.link.home, open: open)) widget.onRemove?.call(dir);
  }

  Widget _header(String dir, {required bool shut, required int count, required bool unread, required int open}) => InkWell(
        onTap: () => _toggle(dir),
        onLongPress: widget.onRemove == null ? null : () => _menu(dir, open),
        onSecondaryTap: widget.onRemove == null ? null : () => _menu(dir, open),
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

  Future<void> _convMenu(Conversation c) async {
    final pinned = widget.pins.conversation(c, widget.sessions);
    if (await pinMenu(context, title: c.title.isEmpty ? '(untitled)' : c.title, pinned: pinned) == 'pin') {
      widget.pins.toggle(c: c);
    }
  }

  Widget _convTile(String dir, Conversation c) => InkWell(
        onTap: () => _resume(dir, c), // offline, starting it says so
        onLongPress: () => _convMenu(c),
        onSecondaryTap: () => _convMenu(c),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(46, 7, 16, 7),
          child: Row(children: [
            StatusDot(_activity(c), size: StatusDot.row),
            const SizedBox(width: 10),
            ToolLogo(c.tool, size: 15),
            const SizedBox(width: 8),
            Expanded(
              child: Text(c.title.isEmpty ? '(untitled)' : c.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
            ),
            if (widget.pins.conversation(c, widget.sessions)) pinMark,
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
