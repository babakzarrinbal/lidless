// The folder menu (long press, or right click on a Mac) in the drawer and on
// the Recent page: take a folder off this Mac's recent folders
// (prefs `recentDirs:<mac>`). See README.md.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/app/theme.dart';
import 'package:uniai/features/workspaces/new_session.dart' show baseName, tildePath;

/// Takes dir off mac's recent folders.
Future<void> forgetRecentDir(SharedPreferences? prefs, String mac, String dir) async {
  final p = prefs;
  if (p == null) return;
  final key = 'recentDirs:$mac';
  await p.setStringList(key, [...?p.getStringList(key)]..remove(dir));
}

/// Shows the folder's menu; true when the user picked "Remove from list".
/// A folder with sessions open stays listed while they are: [open] says how
/// many.
Future<bool> folderMenu(BuildContext context, String dir, {required String home, int open = 0}) async {
  HapticFeedback.selectionClick();
  final a = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.folder_rounded, color: C.amber),
          title: Text(baseName(dir), style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(tildePath(dir, home), overflow: TextOverflow.ellipsis),
        ),
        ListTile(
          enabled: open == 0,
          leading: const Icon(Icons.playlist_remove_rounded),
          title: const Text('Remove from list'),
          subtitle: open == 0 ? null : Text('Its open session${open == 1 ? '' : 's'} keep${open == 1 ? 's' : ''} it here'),
          onTap: () => Navigator.pop(ctx, 'remove'),
        ),
      ]),
    ),
  );
  return a == 'remove';
}
