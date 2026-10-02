// What the session pages ask of the Mac that needs a dialog or several
// calls: run the agent again, resume or carry on a conversation, take over a
// parked one, close a session. [Home] owns the one instance.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/features/workspaces/seen_conversations.dart';
import 'package:uniai/features/chat/transcript_page.dart';
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
    if (c.tool == 'vscode') {
      // VS Code's chat can't be resumed in a terminal: the phone reads it.
      Navigator.push(
        state.context,
        MaterialPageRoute(
          builder: (_) => TranscriptPage(
              link: link, id: c.id, title: c.title, dir: dir, onContinue: (tool) => _carryOn(dir, c, tool)),
        ),
      );
      return;
    }
    final here = terms.sessions.where((s) => c.term != 0 && s.agent?.id == c.term).firstOrNull;
    if (here != null) {
      select(here.id);
      return;
    }
    // Running in a shared terminal it is a session here already (above); this
    // one runs outside them: an editor, or a terminal without the alias.
    final name = tools[c.tool] ?? c.tool;
    final canTake = c.tool == 'claude'; // chat.stop knows how to quit Claude only
    if (c.running) {
      final how = await showDialog<String>(
        context: state.context,
        builder: (ctx) => AlertDialog(
          title: const Text('Open on the Mac'),
          content: Text(canTake
              ? 'Claude has this conversation open on the Mac outside a shared terminal (an editor, or a '
                  'terminal without `uniai shell-setup`).\n\nTake over quits it (it saves first) and carries on '
                  'in a shared terminal: here, on your other devices, and on the Mac with `uniai attach`.'
              : '$name has this conversation open on the Mac outside a shared terminal. Opening it here too '
                  'runs two copies, and neither sees the other\'s new messages.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, canTake ? 'take' : 'both'),
              child: Text(canTake ? 'Take over' : 'Open here too'),
            ),
          ],
        ),
      );
      if (how == null) return;
      if (how == 'take') {
        try {
          await link.call('chat.stop', {'session': c.id}, const Duration(seconds: 15));
        } on RpcError catch (e) {
          if (state.mounted) toast(state.context, e.message, error: true);
          return;
        }
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

  /// Carries a VS Code chat on with [tool] in a new shared session, which
  /// reads the chat's transcript first. True once it started.
  Future<bool> _carryOn(String dir, Conversation c, String tool) async {
    try {
      final h = await link.call('chat.handoff', {'session': c.id}) as Map;
      // The flags of the folder's newest session of that agent, without what resumed it.
      final last = terms.sessions.where((s) => s.dir == dir && s.tool == tool).lastOrNull?.id;
      final base = continueFlags(prefs()?.getString('sessFlags.$last') ?? '').replaceFirst('--continue', '').trim();
      final path = h['path'] as String, prompt = shellQuote(h['prompt'] as String);
      // Both agents may read the transcript's folder without asking. The
      // prompt goes first: --add-dir takes every word after it as a folder.
      final add = '--add-dir ${shellQuote(path.substring(0, path.lastIndexOf('/')))}';
      final id = await terms.start(
          dir, [if (tool == 'copilot') '-i', prompt, base, add].where((s) => s.isNotEmpty).join(' '),
          tool: tool);
      await prefs()?.setString('sessFlags.$id', base);
      if (state.mounted) select(id);
      return true;
    } on RpcError catch (e) {
      if (state.mounted) {
        toast(state.context, e.code == 'unknown' ? 'Update this Mac\'s agent to continue VS Code chats' : e.message, error: true);
      }
      return false;
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
