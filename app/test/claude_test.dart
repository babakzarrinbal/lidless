import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macremote/crypto/noise.dart';
import 'package:macremote/model/chat.dart';
import 'package:macremote/model/claude.dart';
import 'package:macremote/model/terms.dart';
import 'package:macremote/net/link.dart';
import 'package:macremote/net/store.dart';
import 'package:macremote/ui/agent_extras.dart';
import 'package:macremote/ui/chat_view.dart';
import 'package:macremote/ui/new_session.dart';

void main() {
  test('the working line splits into its word and its numbers', () {
    expect(workingParts('✻ Pondering… (12s · ↓ 1.2k tokens · esc to interrupt)'), ('Pondering…', '12s · ↓ 1.2k tokens'));
    expect(workingParts('✢ Thinking… (esc to interrupt)'), ('Thinking…', ''));
    expect(workingParts('· Working'), ('Working', ''));
  });

  test('token counts read like Claude Code prints them', () {
    expect(tokenCount(950), '950');
    expect(tokenCount(127400), '127k');
    expect(tokenCount(1000000), '1.0M');
  });

  test('the transcript carries the context window', () {
    final log = ChatLog()..apply({'path': 'a', 'next': 1, 'items': []});
    expect(log.ctx, isNull);
    var told = 0;
    log.addListener(() => told++);
    log.apply({'path': 'a', 'next': 1, 'items': [], 'ctx': {'tokens': 127000, 'size': 1000000, 'model': 'claude-opus-5-5'}});
    expect(log.ctx!.fraction, closeTo(0.127, 1e-9));
    expect(told, 1);
    log.apply({'path': 'a', 'next': 1, 'items': [], 'ctx': {'tokens': 127000, 'size': 1000000, 'model': 'claude-opus-5-5'}});
    expect(told, 1, reason: 'the same numbers do not redraw');
  });

  test('slash commands match by prefix first', () {
    const all = [SlashCommand('clear', '', 'built-in'), SlashCommand('compact', '', 'built-in'), SlashCommand('mcp', '', 'built-in')];
    expect(SlashCommand.match(all, '/c').map((c) => c.name), ['clear', 'compact', 'mcp']);
    expect(SlashCommand.match(all, '/co').map((c) => c.name), ['compact']);
    expect(SlashCommand.match(all, '/').length, 3);
  });

  test('usage reads the account and orders the limits', () {
    final u = ClaudeUsage.from({
      'statusline': true,
      'at': 1700000000,
      'account': {'email': 'a@b.c', 'plan': 'Max 5x'},
      'limits': {
        'seven_day_opus': {'pct': 10, 'resets': 0},
        'seven_day': {'pct': 41.5, 'resets': 1700100000},
        'five_hour': {'pct': 24, 'resets': 1700010000},
      },
    });
    expect(u.email, 'a@b.c');
    expect(u.limits.map((l) => l.label), ['Session (5 hours)', 'Weekly, all models', 'Weekly, Opus']);
    expect(u.limits.last.resets, isNull);
    final now = DateTime(2026, 1, 1, 12);
    expect(untilText(now.add(const Duration(hours: 2, minutes: 14)), now), '2h 14m');
    expect(untilText(now.add(const Duration(days: 3, hours: 5)), now), '3d 5h');
    expect(agoText(now.subtract(const Duration(minutes: 5)), now), '5m ago');
  });

  test('resuming a conversation keeps the other flags', () {
    expect(resumeFlags('--model opus --continue', 'abc'), '--resume abc --model opus');
    expect(resumeFlags('', 'abc'), '--resume abc');
  });

  testWidgets('the usage card and the context ring draw', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          UsageCard(ClaudeUsage.from({
            'statusline': true,
            'account': {'email': 'a@b.c', 'plan': 'Max 5x'},
            'limits': {'five_hour': {'pct': 24, 'resets': DateTime.now().add(const Duration(hours: 3)).millisecondsSinceEpoch ~/ 1000}},
          })),
          const ContextRing(ContextUse(127000, 1000000, '')),
        ]),
      ),
    ));
    expect(find.text('a@b.c'), findsOneWidget);
    expect(find.text('24%'), findsOneWidget);
    expect(find.textContaining('Resets in 2h'), findsOneWidget);
    expect(find.text('127k'), findsOneWidget);
  });

  testWidgets('the chat shows Claude working with its word', (tester) async {
    final link = Link(const MacPairing(relay: 'h:1', pin: '', room: '1', macPub: '', host: 'mac'), KeyPair.generate());
    final tab = TermTab(1, 'claude', kind: 'claude', session: 's', dir: '/');
    tab.chat.apply({'path': 'a', 'next': 1, 'reset': true, 'items': [{'k': 'user', 'text': 'go'}]});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatView(terms: Terms(link), tab: tab))));
    tab.terminal.resize(80, 10);
    tab.terminal.write('✻ Pondering… (3s · esc to interrupt)\r\n');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Pondering…'), findsOneWidget);
    expect(find.textContaining('3s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
