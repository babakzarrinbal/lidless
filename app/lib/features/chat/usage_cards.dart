// The Mac's status cards: Claude plan usage, Copilot premium requests, and
// tokens per account with their reset.
import 'package:flutter/material.dart';
import 'package:uniai/features/chat/chat.dart';
import 'package:uniai/features/chat/claude.dart';
import 'package:uniai/app/logos.dart';
import 'package:uniai/app/theme.dart';

/// Claude plan usage, as Claude Code last reported it: the account, then one
/// bar per limit with the time until it resets.
class UsageCard extends StatelessWidget {
  const UsageCard(this.u, {super.key});
  final ClaudeUsage u;

  @override
  Widget build(BuildContext context) {
    final hint = u.limits.isEmpty
        ? 'Claude Code on the Mac reported no plan limits: it is signed out, uses an API key, or is out of date.'
        : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const ToolLogo('claude'),
        const SizedBox(width: 8),
        const Text('Claude', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        if (u.plan.isNotEmpty) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(6)),
            child: Text(u.plan, style: const TextStyle(fontSize: 11.5, color: C.dim)),
          ),
        ],
      ]),
      if (u.email.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 3), child: Text(u.email, style: const TextStyle(color: C.dim, fontSize: 13))),
      const SizedBox(height: 10),
      for (final l in u.limits) _LimitBar(l),
      if (hint != null) Text(hint, style: const TextStyle(fontSize: 12.5, color: C.dim)),
      if (u.at != null && u.limits.isNotEmpty)
        Text('As of ${agoText(u.at!)}', style: const TextStyle(fontSize: 11.5, color: C.dim)),
    ]);
  }
}

/// Copilot's monthly premium requests, as GitHub reports them to the Mac's
/// GitHub CLI.
class CopilotCard extends StatelessWidget {
  const CopilotCard(this.u, {super.key});
  final CopilotUsage u;

  @override
  Widget build(BuildContext context) {
    final plan = u.plan.isEmpty ? '' : u.plan[0].toUpperCase() + u.plan.substring(1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.code_rounded, size: 18, color: C.accent),
        const SizedBox(width: 8),
        const Text('Copilot', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        if (plan.isNotEmpty) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(6)),
            child: Text(plan, style: const TextStyle(fontSize: 11.5, color: C.dim)),
          ),
        ],
      ]),
      if (u.login.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 3), child: Text(u.login, style: const TextStyle(color: C.dim, fontSize: 13))),
      const SizedBox(height: 10),
      for (final l in u.limits) _LimitBar(l, detail: u.used != null && u.of != null ? '${u.used} of ${u.of}' : null),
      if (u.ended)
        const Text('This GitHub account has no Copilot subscription now.', style: TextStyle(fontSize: 12.5, color: C.dim))
      else if (u.unlimited)
        const Text('Premium requests are unlimited on this plan.', style: TextStyle(fontSize: 12.5, color: C.dim))
      else if (u.limits.isEmpty)
        const Text('GitHub reported no premium request quota.', style: TextStyle(fontSize: 12.5, color: C.dim)),
    ]);
  }
}

class _LimitBar extends StatelessWidget {
  const _LimitBar(this.l, {this.detail});
  final UsageLimit l;
  final String? detail; // e.g. "90 of 300"

  @override
  Widget build(BuildContext context) {
    final f = (l.pct / 100).clamp(0.0, 1.0);
    final color = f >= 0.9 ? C.red : (f >= 0.7 ? C.amber : C.accent);
    final resets = l.resets;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(l.label, style: const TextStyle(fontSize: 13.5))),
          if (detail != null) Text('$detail  ', style: const TextStyle(fontSize: 12, color: C.dim)),
          Text('${l.pct.round()}%', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: color)),
        ]),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: f, minHeight: 6, color: color, backgroundColor: C.line),
        ),
        if (resets != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(resets.isAfter(DateTime.now()) ? 'Resets in ${untilText(resets)}' : 'Reset already',
                style: const TextStyle(fontSize: 11.5, color: C.dim)),
          ),
      ]),
    );
  }
}

/// What one conversation used, in parts, and on which accounts.
Future<void> showTokenUse(BuildContext context, TokenUse u, {String tool = 'Claude'}) => showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.panel,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.data_usage_rounded, size: 18, color: C.dim),
              const SizedBox(width: 8),
              Text('This conversation: ${tokenCount(u.total)} tokens',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 12),
            TokenParts(u),
            if (u.accounts.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('${u.accounts.length == 1 ? 'Account' : 'Accounts'}: ${u.accounts.join(', ')}',
                  style: const TextStyle(fontSize: 13, color: C.dim)),
            ],
            const SizedBox(height: 6),
            Text('Counted from $tool\'s own transcript, subagents included.',
                style: const TextStyle(fontSize: 11.5, color: C.dim)),
          ]),
        ),
      ),
    );

/// Input / output / cache read / cache write.
class TokenParts extends StatelessWidget {
  const TokenParts(this.u, {super.key});
  final TokenUse u;

  @override
  Widget build(BuildContext context) {
    Widget part(String label, int n) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: C.dim))),
            Text(tokenCount(n), style: const TextStyle(fontSize: 13, fontFamily: mono)),
          ]),
        );
    return Column(children: [
      part('Input', u.input),
      part('Output', u.output),
      part('Cache read', u.cacheRead),
      part('Cache write', u.cacheWrite),
    ]);
  }
}

/// Tokens per account, each with a reset: the accounts [keep] picks, under
/// [title] (none when the card sits under its account, which it then doesn't
/// repeat).
class TokensCard extends StatefulWidget {
  const TokensCard(this.accounts, {super.key, required this.onReset, this.keep, this.title});
  final List<AccountTokens> accounts;
  final Future<List<AccountTokens>> Function(AccountTokens) onReset;
  final bool Function(AccountTokens)? keep;
  final String? title;

  @override
  State<TokensCard> createState() => _TokensCardState();
}

class _TokensCardState extends State<TokensCard> {
  late var _list = _kept(widget.accounts);

  List<AccountTokens> _kept(List<AccountTokens> l) => [for (final a in l) if (widget.keep?.call(a) ?? true) a];
  final _open = <String>{};

  Future<void> _reset(AccountTokens a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset ${a.toolName} tokens?'),
        content: Text('${a.account} starts again from 0. The all-time total stays.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final l = await widget.onReset(a);
      if (mounted) setState(() => _list = _kept(l));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.title != null) ...[
          Text(widget.title!, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
        ],
        if (_list.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text('Tokens used: nothing counted yet.', style: TextStyle(fontSize: 13, color: C.dim)),
          ),
        for (final a in _list) _account(a),
      ]);

  Widget _account(AccountTokens a) {
    final key = '${a.tool}|${a.account}';
    final open = _open.contains(key);
    final since = a.since == null ? '' : '${a.reset ? 'since reset ' : 'since '}${dayText(a.since!)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => open ? _open.remove(key) : _open.add(key)),
          child: Row(children: [
            ToolLogo(a.tool, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(widget.title == null ? 'Tokens used' : a.account,
                        overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                  ),
                  if (a.current && widget.title != null) ...[
                    const SizedBox(width: 6),
                    const Text('signed in', style: TextStyle(fontSize: 11, color: C.green)),
                  ],
                ]),
                Text([since, if (a.reset) 'all time ${tokenCount(a.all)}'].where((s) => s.isNotEmpty).join(' · '),
                    style: const TextStyle(fontSize: 11.5, color: C.dim)),
              ]),
            ),
            Text(tokenCount(a.used.total), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            IconButton(
              tooltip: 'Reset',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.restart_alt_rounded, size: 19, color: C.dim),
              onPressed: () => _reset(a),
            ),
          ]),
        ),
        if (open) Padding(padding: const EdgeInsets.only(left: 24, right: 40, top: 4), child: TokenParts(a.used)),
      ]),
    );
  }
}
