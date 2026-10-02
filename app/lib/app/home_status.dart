// The Mac's status sheet: Claude and Copilot usage, tokens per account,
// battery and power, and the "stay awake with the lid closed" switch.
import 'package:flutter/material.dart';

import 'package:uniai/features/chat/usage_cards.dart';
import 'package:uniai/app/session_view.dart';
import 'package:uniai/app/theme.dart';
import 'package:uniai/features/chat/claude.dart';
import 'package:uniai/net/link.dart';

/// Shows the Mac's status sheet: usage and tokens, power, and the lid switch.
/// [currentView] is the session on screen, where the lid command is typed.
Future<void> showMacStatus(BuildContext context, Link link, SessionViewState? Function() currentView) async {
  Map? s;
  ClaudeUsage? usage;
  final u = link
      .call('usage', null, const Duration(seconds: 25)) // the Mac asks Claude Code and GitHub
      .then((r) => ClaudeUsage.from(r as Map))
      .then<ClaudeUsage?>((v) => v, onError: (_) => null); // an older agent has no usage
  try {
    s = await link.call('sys.status', null, const Duration(seconds: 8)) as Map;
    usage = await u;
  } catch (e) {
    if (context.mounted) toast(context, '$e', error: true);
    return;
  }
  if (!context.mounted) return;
  final lid = s['lidAwake'] == true;
  Future<List<AccountTokens>> reset(AccountTokens a) async {
    final r = await link.call('tokens.reset', {'tool': a.tool, 'account': a.account}, const Duration(seconds: 30));
    return [for (final t in r as List) AccountTokens.from(t as Map)];
  }

  // Each account's tokens sit under its plan; accounts not signed in, below.
  bool claudes(AccountTokens a) => a.tool == 'claude' && a.account == usage?.email;
  bool copilots(AccountTokens a) => a.tool == 'copilot' && a.account == usage?.copilot?.login;
  bool others(AccountTokens a) => !claudes(a) && !copilots(a);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    // Short of the top, so dragging it down never pulls the notifications.
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
    builder: (ctx) => SafeArea(
      top: false,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 8),
          child: Row(children: [
            Expanded(
              child: Text(s!['host'] ?? link.host,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ),
            IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(ctx)),
          ]),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (usage != null) ...[
            UsageCard(usage),
            TokensCard(usage.tokens, keep: claudes, onReset: reset),
            const Divider(height: 28),
            if (usage.copilot != null) ...[
              CopilotCard(usage.copilot!),
              TokensCard(usage.tokens, keep: copilots, onReset: reset),
              const Divider(height: 28),
            ],
            if (usage.tokens.any(others)) ...[
              TokensCard(usage.tokens, keep: others, title: 'Other accounts', onReset: reset),
              const Text('Copilot\'s tokens count once a Copilot session ends.',
                  style: TextStyle(fontSize: 11.5, color: C.dim)),
              const Divider(height: 28),
            ],
          ],
          const Text('This Mac', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          _row(Icons.battery_charging_full_rounded, 'Battery', s['battery'] ?? '—'),
          _row(Icons.power_rounded, 'Power', s['power'] ?? '—'),
          _row(Icons.coffee_rounded, 'Kept awake while idle', s['keepAwake'] == true ? 'yes' : 'no'),
          const Divider(height: 28),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: lid,
            title: const Text('Stay awake with the lid closed'),
            subtitle: Text(
              lid
                  ? 'On. Sleep is disabled until you switch this off.'
                  : 'Runs “sudo pmset -a disablesleep 1” in a new terminal; type your Mac password there.',
              style: const TextStyle(fontSize: 12.5, color: C.dim),
            ),
            onChanged: (v) {
              Navigator.pop(ctx);
              final view = currentView();
              if (view == null) {
                toast(context, 'Start a session first', error: true);
                return;
              }
              view.runInShell('sudo pmset -a disablesleep ${v ? 1 : 0}\r', newTab: true);
              toast(context, 'Enter your Mac password in the shell');
            },
          ),
          if (lid)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'A closed MacBook in a bag can get hot. Switch this off when you are done.',
                style: TextStyle(color: C.amber, fontSize: 12.5),
              ),
            ),
        ]),
          ),
        ),
      ]),
    ),
  );
}

Widget _row(IconData i, String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(i, size: 18, color: C.dim),
        const SizedBox(width: 12),
        Text(k, style: const TextStyle(color: C.dim)),
        const Spacer(),
        Flexible(child: Text(v, textAlign: TextAlign.end, overflow: TextOverflow.ellipsis)),
      ]),
    );
