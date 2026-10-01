import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macremote/crypto/noise.dart';
import 'package:macremote/model/chat.dart';
import 'package:macremote/model/terms.dart';
import 'package:macremote/net/link.dart';
import 'package:macremote/net/store.dart';
import 'package:macremote/ui/chat_view.dart';
import 'package:xterm/xterm.dart';

const _first = {
  'path': 'a.jsonl',
  'next': 100,
  'reset': true,
  'items': [
    {'k': 'user', 'text': 'fix the build'},
    {'k': 'text', 'text': 'Looking at **main.go**:\n\n```go\nfunc main() {}\n```'},
    {'k': 'tool', 'id': 't1', 'name': 'Edit', 'text': '~/x/main.go', 'detail': '- a\n+ b'},
  ],
};

void main() {
  test('results attach to their tool call; a new transcript starts over', () {
    final log = ChatLog()..apply(_first);
    expect(log.items.map((e) => e.kind), ['user', 'text', 'tool']);
    expect(log.items.last.result, isNull);
    log.apply({
      'path': 'a.jsonl',
      'next': 160,
      'items': [
        {'k': 'result', 'id': 't1', 'text': 'boom', 'err': true},
        {'k': 'result', 'id': 'gone', 'text': 'orphan'},
      ],
    });
    expect(log.items.length, 3);
    expect(log.items.last.result, 'boom');
    expect(log.items.last.err, isTrue);
    expect(log.next, 160);
    log.apply({'path': 'b.jsonl', 'next': 10, 'items': []});
    expect(log.items, isEmpty);
    expect(log.path, 'b.jsonl');
  });

  test('the live screen finds a permission question and the working line', () {
    final t = Terminal()..resize(80, 16);
    t.write('⏺ Bash(rm -rf build)\r\n\r\n');
    t.write(' Bash command\r\n   rm -rf build\r\n\r\n');
    t.write(' Do you want to proceed?\r\n');
    t.write(' ❯ 1. Yes\r\n');
    t.write('   2. Yes, and don\'t ask again for rm commands\r\n');
    t.write('   3. No, and tell Claude what to do differently (esc)\r\n');
    final live = LiveScreen.of(t);
    expect(live.question, 'Do you want to proceed?');
    expect(live.options.map((o) => o.$1), ['1', '2', '3']);
    expect(live.options.first.$2, 'Yes');

    final busy = Terminal()..resize(80, 10);
    busy.write('Here is a plan:\r\n1. one\r\n2. two\r\n\r\n✻ Thinking… (12s · esc to interrupt)\r\n');
    final l2 = LiveScreen.of(busy);
    expect(l2.asking, isFalse, reason: 'a numbered list in an answer is not a question');
    expect(l2.status, '✻ Thinking… (12s · esc to interrupt)');

    final compacting = Terminal()..resize(80, 10);
    compacting.write('> /compact\r\n\r\n✶ Compacting conversation… (8s)\r\n');
    expect(LiveScreen.of(compacting).status, '✶ Compacting conversation… (8s)');
    expect(workingParts('✶ Compacting conversation… (8s)'), ('Compacting conversation…', '8s'));
    final done = Terminal()..resize(80, 10);
    done.write('⏺ Done… more or less.\r\n\r\n✻ Worked for 12s\r\n');
    expect(LiveScreen.of(done).status, isNull);
  });

  testWidgets('the chat shows messages, markdown and a tool row that opens', (tester) async {
    final link = Link(
      const MacPairing(relay: 'h:1', pin: '', room: '1', macPub: '', host: 'mac'),
      KeyPair.generate(),
    );
    final terms = Terms(link);
    final tab = TermTab(1, 'claude', kind: 'claude', session: 's', dir: '/');
    tab.chat.apply(_first);
    tab.chat.apply({
      'path': 'a.jsonl',
      'next': 120,
      'items': [
        {'k': 'result', 'id': 't1', 'text': 'patched'},
      ],
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatView(terms: terms, tab: tab))));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('fix the build'), findsOneWidget);
    expect(find.textContaining('func main()'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.textContaining('patched'), findsNothing);
    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(find.textContaining('patched'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stop the poll timers
  });
}
