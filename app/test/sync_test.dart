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
}
