// The recent page, which the app opens on: new session, the Mac's newest
// conversations from every folder, and recent folders.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/features/workspaces/recent_list.dart';
import 'package:uniai/app/theme.dart';
import 'package:uniai/features/chat/claude.dart' show Conversation;
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/workspaces/new_session.dart';
import 'package:uniai/net/link.dart';

class HomeRecent extends StatelessWidget {
  const HomeRecent({
    super.key,
    required this.link,
    required this.prefs,
    required this.mac,
    required this.all,
    required this.onNew,
    required this.onResume,
  });
  final Link link;
  final SharedPreferences? prefs;
  final String mac;
  final List<Session> all; // the sessions open on the Mac
  final void Function({String? dir}) onNew;
  final Future<void> Function(String dir, Conversation c, {String? flagsOf}) onResume;

  @override
  Widget build(BuildContext context) {
    final recent = prefs?.getStringList('recentDirs:$mac') ?? [];
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (all.isEmpty) ...[
              const SizedBox(height: 12),
              const Icon(Icons.auto_awesome_rounded, size: 40, color: C.accent),
              const SizedBox(height: 14),
              Text('No sessions open on ${link.host}',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text('Pick up a recent one, or start Claude Code, Copilot or a terminal in a folder.',
                  textAlign: TextAlign.center, style: TextStyle(color: C.dim)),
              const SizedBox(height: 22),
            ],
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: link.online ? () => onNew() : null,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New session'),
            ),
            const SizedBox(height: 18),
            RecentList(
              key: ValueKey(prefs == null),
              link: link,
              prefs: prefs,
              mac: mac,
              sessions: all,
              onResume: onResume,
            ),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 22),
              const Text('Recent folders', style: TextStyle(color: C.dim, fontSize: 13)),
              const SizedBox(height: 6),
              for (final d in recent)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_rounded, color: C.amber),
                  title: Text(baseName(d)),
                  subtitle: Text(tildePath(d, link.home), overflow: TextOverflow.ellipsis),
                  onTap: link.online ? () => onNew(dir: d) : null,
                ),
            ],
          ]),
        ),
      ),
    );
  }
}
