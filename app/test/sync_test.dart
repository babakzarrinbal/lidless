import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:macremote/model/terms.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_test.dart' show FakeLink;

void main() {
  testWidgets('a terminal opened on another device shows up, and one closed there ends here', (tester) async {
    SharedPreferences.setMockInitialValues({});
    Map term(int id, String session, {String kind = 'claude'}) =>
        {'id': id, 'title': kind, 'kind': kind, 'session': session, 'dir': '/p', 'end': 0};
    final link = FakeLink({
      'term.list': [term(7, 's1')],
      'term.attach': {'end': 0},
    });
    final terms = Terms(link);
    await tester.pump(const Duration(milliseconds: 100));
    expect(terms.sessions.map((s) => s.id), ['s1']);

    // The laptop started Claude (`macremote claude`): the Mac says so.
    link.answers['term.list'] = [term(7, 's1'), term(9, 's2')];
    link.macEvents.add(('terms', null));
    await tester.pump(const Duration(milliseconds: 100));
    expect(terms.sessions.map((s) => s.id), ['s1', 's2']);
    expect(link.calls.where((c) => c == 'term.attach'), hasLength(2)); // only the new one attached again
    expect(terms.session('s2')!.agent!.unread, isFalse); // its past is not news

    // It was quit on the laptop.
    link.answers['term.list'] = [term(7, 's1')];
    link.macEvents.add(('terms', null));
    await tester.pump(const Duration(milliseconds: 100));
    expect(terms.session('s2')!.agent!.exited, isTrue);
    expect(terms.session('s1')!.agent!.exited, isFalse);
    terms.dispose();
  });

  testWidgets('a terminal this phone opens is one tab even when the Mac announces it first', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final link = FakeLink({
      'term.list': <Map>[],
      'term.attach': {'end': 0},
    });
    final terms = Terms(link);
    await tester.pump(const Duration(milliseconds: 100));
    final t9 = {'id': 9, 'title': 'zsh', 'kind': 'shell', 'session': 's1', 'dir': '/p', 'end': 0};
    link.answers['term.list'] = [t9];
    link.answers['term.open'] = t9;
    link.macEvents.add(('terms', null)); // the event lands before the reply
    await tester.pump(const Duration(milliseconds: 50));
    final t = await terms.open(session: 's1', dir: '/p');
    expect(terms.tabs, [t]);
    expect(link.calls.where((c) => c == 'term.attach'), hasLength(1));
    terms.dispose();
  });

  group('unread across devices', () {
    late FakeLink link;
    late Terms terms;
    final told = <String>[], read = <String>[];
    Future<void> boot(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      told.clear();
      read.clear();
      link = FakeLink({
        'term.list': [
          {'id': 7, 'title': 'claude', 'kind': 'claude', 'session': 's1', 'dir': '/p', 'end': 0},
        ],
        'term.attach': {'end': 0},
        'term.seen': true,
      });
      terms = Terms(link)
        ..onUnread = ((t, _) => told.add(t.session))
        ..onRead = read.add;
      await tester.pump(const Duration(milliseconds: 100));
    }

    var off = 0;
    void out(String s) {
      final b = Uint8List.fromList(utf8.encode(s));
      link.termOut[7]!(off, b);
      off += b.length;
    }

    testWidgets('a tab never on screen does not send its 80x24', (tester) async {
      off = 0;
      await boot(tester);
      final attach = link.sent.firstWhere((p) => p.$1 == 'term.attach').$2!;
      expect([attach['cols'], attach['rows']], [0, 0]);
      terms.dispose();
    });

    testWidgets('a redraw after a resize elsewhere is not news', (tester) async {
      off = 0;
      await boot(tester);
      final t = terms.tabs.single;
      link.macEvents.add(('term.size', {'id': 7, 'cols': 40, 'rows': 30, 'at': 0}));
      await tester.pump();
      out('x' * 2000);
      await tester.pump(const Duration(seconds: 3));
      expect(t.unread, isFalse);
      expect(told, isEmpty);
      terms.dispose();
    });

    testWidgets('only real work notifies, and a read on another phone clears it', (tester) async {
      off = 0;
      await boot(tester);
      final t = terms.tabs.single;
      out('typed on the laptop ' * 100); // no status line: Claude did nothing
      await tester.pump(const Duration(seconds: 3));
      expect([t.unread, told], [false, isEmpty]);

      out('\x1b[2J\x1b[H✻ Thinking… (3s · esc to interrupt)\r\n');
      out('\x1b[2J\x1b[H${'the answer ' * 100}');
      await tester.pump(const Duration(seconds: 3));
      expect(t.unread, isTrue);
      expect(told, ['s1']);

      link.macEvents.add(('term.seen', {'id': 7, 'seen': off}));
      await tester.pump();
      expect(t.unread, isFalse);
      expect(read, contains('s1'));
      terms.dispose();
    });
  });
}
