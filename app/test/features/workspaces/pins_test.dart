import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uniai/features/chat/claude.dart';
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/workspaces/pins.dart';
import 'package:uniai/features/workspaces/recent_list.dart';

import '../../support/fakes.dart';

void main() {
  test('a pin outlasts its session through the conversation, per Mac', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final pins = Pins('m', prefs: prefs);
    final s = Session('s1', '/p')..agent = TermTab(7, 'claude', kind: 'claude', session: 's1', dir: '/p');
    final c = Conversation.from({'id': 'c1', 'term': 7});
    final other = Conversation.from({'id': 'c2'});

    pins.toggle(s: s); // from the drawer: the conversation is not known yet
    expect(pins.session(s), isTrue);
    expect(pins.conversation(c, [s]), isTrue, reason: 'open in a pinned session');
    expect(pins.conversation(other, [s]), isFalse);

    pins.learn([c, other], [s]);
    pins.prune([]); // closed
    expect(pins.session(s), isFalse);
    expect(pins.conversation(c, []), isTrue);

    pins.resumed(c, 's9');
    pins.resumed(other, 's10');
    expect(prefs.getStringList('pinned:m')!..sort(), ['c:c1', 's:s9']);
    expect(Pins('m', prefs: prefs).conversation(c, []), isTrue, reason: 'kept on this device');
    expect(Pins('other-mac', prefs: prefs).conversation(c, []), isFalse);

    pins.toggle(s: Session('s9', '/p'), c: c); // either pinned: unpins both
    expect(prefs.getStringList('pinned:m'), isEmpty);
  });

  testWidgets('a long press pins a recent session to the top', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final pins = Pins('m', prefs: prefs);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Widget page() => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RecentList(
                link: FakeLink({}),
                prefs: prefs,
                mac: 'm',
                sessions: const [],
                pins: pins,
                onResume: (_, _) {},
                load: () async => [
                  Conversation.from({'id': 'a', 'title': 'Newest', 'mtime': now, 'dir': '/w'}),
                  Conversation.from({'id': 'b', 'title': 'Older', 'mtime': now - 60, 'dir': '/w'}),
                ],
              ),
            ),
          ),
        );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('Newest'), lessThan(y('Older')));

    await tester.longPress(find.text('Older'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin to the top'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page()); // Home rebuilds on a pin
    await tester.pumpAndSettle();
    expect(y('Older'), lessThan(y('Newest')));
    expect(prefs.getStringList('pinned:m'), ['c:b']);
  });
}
