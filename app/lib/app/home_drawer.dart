// The side drawer: the paired Macs, then the Mac's folders with their
// sessions, and Lock / Unpair.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/features/workspaces/status_dot.dart';
import 'package:uniai/app/logos.dart';
import 'package:uniai/app/theme.dart';
import 'package:uniai/features/chat/claude.dart' show Conversation;
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/terminals/terms.dart';
import 'package:uniai/features/workspaces/workspaces.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/net/store.dart';

class HomeDrawer extends StatelessWidget {
  const HomeDrawer({
    super.key,
    required this.link,
    required this.terms,
    required this.macs,
    required this.prefs,
    required this.mac,
    required this.all,
    required this.cur,
    required this.recent,
    required this.closeDrawer,
    required this.onSwitch,
    required this.onManageMacs,
    required this.onNew,
    required this.onShowRecent,
    required this.onResume,
    required this.onRemoveDir,
    required this.onSelect,
    required this.onClose,
    required this.onLock,
    required this.onUnpair,
  });
  final Link link;
  final Terms terms;
  final List<MacPairing> macs;
  final SharedPreferences? prefs;
  final String mac;
  final List<Session> all; // the sessions open on the Mac
  final Session? cur; // null: the recent page
  final bool recent;
  final VoidCallback closeDrawer, onManageMacs, onShowRecent, onLock, onUnpair;
  final void Function(MacPairing) onSwitch;
  final void Function({String? dir}) onNew;
  final Future<void> Function(String dir, Conversation c) onResume;
  final void Function(String dir) onRemoveDir;
  final void Function(String id) onSelect;
  final void Function(Session) onClose;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: C.panel,
      child: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
              _section('Devices'),
              // This device first, its own name underneath.
              for (final m in [...macs.where((m) => m.isLocal), ...macs.where((m) => !m.isLocal)])
                ListTile(
                  dense: true,
                  leading: Icon(Icons.laptop_mac_rounded, color: m.room == link.pairing.room ? C.accent : C.dim),
                  title: Text(m.isLocal ? 'This device' : m.room == link.pairing.room ? link.host : m.name,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: m.isLocal
                      ? Text(m.room == link.pairing.room ? link.hostname : m.host,
                          style: const TextStyle(fontSize: 12, color: C.dim))
                      : null,
                  trailing: m.room == link.pairing.room ? const Icon(Icons.check_rounded, color: C.accent) : null,
                  onTap: () {
                    closeDrawer();
                    onSwitch(m);
                  },
                ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.tune_rounded, color: C.dim),
                title: const Text('Manage devices'),
                subtitle: const Text('Pair, rename, remove, shell', style: TextStyle(fontSize: 12)),
                onTap: () {
                  closeDrawer();
                  onManageMacs();
                },
              ),
              const Divider(height: 20),
              Row(children: [
                Expanded(child: _section('Folders on ${link.host}')),
                IconButton(
                  tooltip: 'New session',
                  icon: const Icon(Icons.add_rounded),
                  onPressed: link.online ? () => onNew() : null,
                ),
              ]),
              ListTile(
                dense: true,
                selected: recent,
                leading: const Icon(Icons.history_rounded),
                title: const Text('Recent sessions', style: TextStyle(fontSize: 14.5)),
                onTap: onShowRecent,
              ),
              if (all.isEmpty && terms.synced)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text('None yet', style: TextStyle(color: C.dim)),
                ),
              WorkspaceList(
                link: link,
                prefs: prefs,
                mac: mac,
                sessions: all,
                dirs: [
                  ...{
                    for (final s in all) s.dir,
                    ...?prefs?.getStringList('recentDirs:$mac'),
                  },
                ],
                tile: (s) => _sessionTile(s, s == cur),
                onNew: (dir) => onNew(dir: dir),
                onResume: (dir, c) => onResume(dir, c),
                onRemove: onRemoveDir,
              ),
            ]),
          ),
          const Divider(height: 1),
          Row(children: [
            Expanded(
              child: TextButton.icon(
                onPressed: onLock,
                icon: const Icon(Icons.lock_rounded, size: 18),
                label: const Text('Lock'),
              ),
            ),
            if (!link.pairing.isLocal) Expanded(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: C.red),
                onPressed: onUnpair,
                icon: const Icon(Icons.link_off_rounded, size: 18),
                label: const Text('Unpair'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
        child: Text(t.toUpperCase(),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: C.dim, fontSize: 11.5, letterSpacing: .8, fontWeight: FontWeight.w600)),
      );

  Widget _sessionTile(Session s, bool sel) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 2, 8, 2),
      child: Material(
        color: sel ? C.accent.withValues(alpha: .14) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            onSelect(s.id);
            closeDrawer();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
            child: Row(children: [
              StatusDot(s.activity, size: StatusDot.row),
              const SizedBox(width: 10),
              ToolLogo(s.tool),
              const SizedBox(width: 10),
              Expanded(
                child: Text(s.agent?.title.isNotEmpty == true && s.agent!.title != s.tool ? s.agent!.title : s.toolName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              IconButton(
                tooltip: 'Close session',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 18, color: C.dim),
                onPressed: () => onClose(s),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
