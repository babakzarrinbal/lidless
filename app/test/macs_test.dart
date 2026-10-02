import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniai/model/terms.dart';
import 'package:uniai/net/store.dart';
import 'package:uniai/ui/devices.dart';
import 'package:uniai/ui/macs.dart';
import 'package:uniai/ui/terminal_panel.dart';

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

  testWidgets('shell tabs: holding + or tapping ▾ picks the shell; tapping + opens the default', (tester) async {
    final link = FakeLink({'term.list': []});
    var picks = 0, news = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TermTabs(terms: Terms(link), session: Session('s', '/tmp'), onNew: () => news++, onPick: () => picks++),
      ),
    ));
    await tester.longPress(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(picks, 1);
    await tester.tap(find.byIcon(Icons.arrow_drop_down_rounded));
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect((picks, news), (2, 1));
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

  testWidgets('Devices page: this device on top, its paired phones, a pairing code', (tester) async {
    final link = FakeLink({
      'term.list': [],
      'shell.list': {'shells': ['/bin/zsh'], 'default': '', 'login': '/bin/zsh'},
      'devices.list': [
        {'name': 'Pixel', 'pub': 'aa', 'added': '2026-10-01T10:00:00.123456789+02:00', 'online': true},
      ],
      'devices.rename': [
        {'name': 'Work phone', 'pub': 'aa', 'added': '2026-10-01T10:00:00Z', 'online': true},
      ],
      'devices.pair': {
        'code': 'mr1.abc',
        'host': 'Mac',
        'expires': DateTime.now().add(const Duration(minutes: 10)).toIso8601String(),
      },
    })..pairing = MacPairing.local();
    const other = MacPairing(relay: 'r:1', pin: 'p', room: 'ffffffffffffffffffff', macPub: 'k', host: 'mini.local');
    await tester.pumpWidget(MaterialApp(
      home: MacsPage(
        link: link,
        terms: Terms(link),
        macs: [other, link.pairing],
        onSwitch: (_) {},
        onAdd: () {},
        onRename: (m, n) async {},
        onForget: (m) async {},
      ),
    ));
    await tester.pumpAndSettle();
    // This device first, its name underneath; the other Mac after.
    expect(tester.getTopLeft(find.text('This device')).dy, lessThan(tester.getTopLeft(find.text('mini.local')).dy));
    expect(find.textContaining('connected now'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Work phone');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(link.sent.last.$1, 'devices.rename');
    expect(link.sent.last.$2, {'pub': 'aa', 'name': 'Work phone'});
    expect(find.text('Work phone'), findsOneWidget);

    await tester.tap(find.text('Pair a new device'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(PairCodeDialog), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  testWidgets('Devices page: an older core says to update', (tester) async {
    final link = FakeLink({'term.list': []})..pairing = MacPairing.local();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PairedDevicesSection(link: link))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Update the core'), findsOneWidget);
    expect(find.text('Pair a new device'), findsNothing);
  });
}
