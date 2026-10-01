import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macremote/model/terms.dart';
import 'package:macremote/net/store.dart';
import 'package:macremote/ui/macs.dart';

import 'home_test.dart' show FakeLink;

void main() {
  test('a nickname survives storage and re-pairing, and names the Mac', () {
    const p = MacPairing(relay: 'r:1', pin: 'p', room: 'room', macPub: 'k', host: 'mbp.local', phoneKey: 'aa');
    expect(p.name, 'mbp.local');
    final n = p.withNick('Office');
    expect(n.name, 'Office');
    expect(MacPairing.fromJson(n.toJson()).nick, 'Office');
    expect(n.paired(host: 'mbp2.local').nick, 'Office');
    expect(n.withKey('bb').nick, 'Office');
    expect(n.withNick(null).name, 'mbp.local');
  });

  test('shell info: the default falls back to the login shell', () {
    final i = ShellInfo.from({'shells': ['/bin/bash', '/bin/zsh'], 'default': '', 'login': '/bin/zsh'});
    expect(i.current, '/bin/zsh');
    expect(ShellInfo.from({'shells': [], 'default': '/bin/bash', 'login': '/bin/zsh'}).current, '/bin/bash');
    expect(shellName('/opt/homebrew/bin/fish'), 'fish');
  });

  testWidgets('Macs page: rename and remove another Mac, see the shell', (tester) async {
    final link = FakeLink({
      'term.list': [],
      'shell.list': {'shells': ['/bin/bash', '/bin/zsh'], 'default': '', 'login': '/bin/zsh'},
    });
    const other = MacPairing(relay: 'r:1', pin: 'p', room: 'ffffffffffffffffffff', macPub: 'k', host: 'mini.local');
    final renamed = <String?>[], forgotten = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: MacsPage(
        link: link,
        terms: Terms(link),
        macs: [link.pairing, other],
        onSwitch: (_) {},
        onAdd: () {},
        onRename: (m, n) async => renamed.add(n),
        onForget: (m) async => forgotten.add(m.room),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Mac'), findsOneWidget);
    expect(find.text('zsh · /bin/zsh (login shell)'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Studio');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(renamed, ['Studio']);
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('mini.local'), findsOneWidget); // the real name underneath

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(forgotten, [other.room]);
    expect(find.text('Studio'), findsNothing);
  });
}
