// What the session pages ask of the Mac that needs a dialog or several
// calls: run the agent again, resume a conversation or move it here from
// outside the shared terminals (Claude, Copilot, VS Code's chats), take over
// a parked one, close a session. [Home] owns the one instance.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/features/workspaces/seen_conversations.dart';
import 'package:uniai/app/theme.dart';
import 'package:uniai/features/chat/claude.dart';
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/terminals/terms.dart';
import 'package:uniai/features/workspaces/new_session.dart';
import 'package:uniai/net/link.dart';

class SessionFlows {
  SessionFlows(this.state, this.terms, {required this.prefs, required this.select, required this.closeDrawer});
  final State state; // the Home that shows the dialogs
  final Terms terms;
  final SharedPreferences? Function() prefs; // loaded after the first frame
  final void Function(String id) select;
  final VoidCallback closeDrawer;

  Link get link => terms.link;

  /// Runs the session's agent again with --continue: typed into its terminal
  /// when that still runs (the agent was quit), else in a new one.
  Future<void> restart(Session s) async {
    final flags = prefs()?.getString('sessFlags.${s.id}') ?? '';
    final old = s.agent;
    final cmd = s.tool == 'cli' ? null : Terms.command(s.tool, continueFlags(flags));
    try {
      if (old != null && !old.exited) {
        if (cmd != null) terms.type(old, '$cmd\r');
        return;
      }
      await terms.open(session: s.id, dir: s.dir, kind: s.tool, cmd: cmd, sizeLike: old);
      if (old != null) terms.close(old);
    } on RpcError catch (e) {
      if (state.mounted) toast(state.context, e.message, error: true);
    }
  }

  /// Shows a conversation picked from the folder's history: the session that
  /// already has it open, or a new session resuming it.
  Future<void> openConversation(Session from, Conversation c) =>
      resumeIn(from.dir, c, flagsOf: from.tool == c.tool ? from.id : null);

  /// Resumes a conversation in [dir] with the agent that had it, with the
  /// flags of session [flagsOf] or else of the folder's newest session of
  /// that agent.
  Future<void> resumeIn(String dir, Conversation c, {String? flagsOf}) async {
    closeDrawer();
    final here = terms.sessions.where((s) => c.term != 0 && s.agent?.id == c.term).firstOrNull;
    if (here != null) {
      select(here.id);
      return;
    }
    if (c.tool == 'vscode') {
      await _moveVSCode(dir, c);
      return;
    }
    // Running in a shared terminal it is a session here already (above); this
    // one runs outside them: an editor, or a terminal without the alias.
    if (c.running) {
      final name = tools[c.tool] ?? c.tool;
      final move = await showDialog<bool>(
        context: state.context,
        builder: (ctx) => AlertDialog(
          title: const Text('Open on the Mac'),
          content: Text('$name has this conversation open on the Mac outside bz-uniai (an editor, or a '
              'terminal without `uniai shell-setup`).\n\nMove here quits it there (it saves first) and carries '
              'on in a shared terminal: here, on your other devices, and on the Mac with `uniai attach`.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Move here')),
          ],
        ),
      );
      if (move != true) return;
      try {
        await link.call('chat.stop', {'session': c.id}, const Duration(seconds: 15));
      } on RpcError catch (e) {
        if (state.mounted) toast(state.context, e.message, error: true);
        return;
      }
    }
    flagsOf ??= terms.sessions.where((s) => s.dir == dir && s.tool == c.tool).lastOrNull?.id;
    final flags = resumeFlags(prefs()?.getString('sessFlags.$flagsOf') ?? '', c.id);
    try {
      final id = await terms.start(dir, flags, tool: c.tool);
      await prefs()?.setString('sessFlags.$id', flags);
      if (state.mounted) select(id);
    } on RpcError catch (e) {
      if (state.mounted) toast(state.context, e.message, error: true);
    }
  }

  /// Moves a VS Code chat here: Copilot carries it on in a new shared
  /// session, reading the chat so far first. From then on that Copilot
  /// session stands in for the chat in the lists (the agent's WithVSCode).
  Future<void> _moveVSCode(String dir, Conversation c) async {
    try {
      final h = await link.call('chat.handoff', {'session': c.id}) as Map;
      // The flags of the folder's newest Copilot session, without what resumed it.
      final last = terms.sessions.where((s) => s.dir == dir && s.tool == 'copilot').lastOrNull?.id;
      final base = continueFlags(prefs()?.getString('sessFlags.$last') ?? '').replaceFirst('--continue', '').trim();
      final path = h['path'] as String, prompt = shellQuote(h['prompt'] as String);
      // Copilot may read the transcript's folder without asking. The prompt
      // goes first: --add-dir takes every word after it as a folder.
      final add = '--add-dir ${shellQuote(path.substring(0, path.lastIndexOf('/')))}';
      final id = await terms.start(dir, ['-i', prompt, base, add].where((s) => s.isNotEmpty).join(' '), tool: 'copilot');
      await prefs()?.setString('sessFlags.$id', base);
      if (state.mounted) select(id);
    } on RpcError catch (e) {
      if (state.mounted) {
        toast(state.context, e.code == 'unknown' ? 'Update this Mac\'s agent to move VS Code chats here' : e.message,
            error: true);
      }
    }
  }

  Future<void> closeSession(Session s) async {
    final n = s.shells.where((t) => !t.exited).length;
    final ok = await showDialog<bool>(
      context: state.context,
      builder: (ctx) => AlertDialog(
        title: Text('Close ${s.name}?'),
        content: Text('This ends ${s.toolName}${n == 0 ? '' : ' and $n shell${n == 1 ? '' : 's'}'} on the Mac.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final c in await terms.closeSession(s.id)) {
      _seen.readNow(c); // seen here: gray in the lists, not unread
    }
    prefs()?.remove('sessFlags.${s.id}');
  }

  SeenConversations get _seen => SeenConversations(prefs(), macKey(link));

  /// Coming back: a Claude an older version parked starts again, unless the conversation was
  /// picked up elsewhere meanwhile; then it's the user's call.
  Future<void> enter(Session s) async {
    if (s.agent?.parked != true || !_waking.add(s.id)) return;
    try {
      await _unpark(s);
    } finally {
      _waking.remove(s.id);
    }
  }

  final _waking = <String>{};

  Future<void> _unpark(Session s) async {
    try {
      await terms.unpark(s);
    } on RpcError catch (e) {
      if (e.code != 'busy' || !state.mounted) {
        if (state.mounted) toast(state.context, e.message, error: true);
        return;
      }
      final take = await showDialog<bool>(
        context: state.context,
        builder: (ctx) => AlertDialog(
          title: const Text('Open on the Mac'),
          content: const Text('This conversation was picked up on the Mac (a terminal or an editor) while you were away.\n\n'
              'Take over quits that Claude (it saves first) and carries on here.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Leave it there')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Take over')),
          ],
        ),
      );
      if (take != true) return;
      try {
        await terms.unpark(s, take: true);
      } on RpcError catch (e) {
        if (state.mounted) toast(state.context, e.message, error: true);
      }
    }
  }
}
