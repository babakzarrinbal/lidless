import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macremote/crypto/noise.dart';
import 'package:macremote/model/terms.dart';
import 'package:macremote/net/link.dart';
import 'package:macremote/net/store.dart';
import 'package:macremote/ui/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Mac that answers from a table, already connected.
class FakeLink extends Link {
  FakeLink(this.answers)
      : super(const MacPairing(relay: 'r:1', pin: '', room: '0123456789abcdef0123', macPub: '', host: 'Mac'),
            KeyPair.generate()) {
    state = LinkState.online;
    epoch = 1;
    info = {'host': 'Mac', 'home': '/Users/me', 'roots': ['/Users/me']};
  }
  final Map<String, dynamic> answers;
  final calls = <String>[];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params, Duration timeout = const Duration(seconds: 45)]) async {
    calls.add(method);
    if (answers.containsKey(method)) return answers[method];
    throw RpcError('unknown', 'unknown method $method');
  }
}

void main() {
  testWidgets('the recent page lists conversations while sessions are open', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final link = FakeLink({
      'term.list': [
        {'id': 7, 'title': 'claude', 'kind': 'claude', 'session': 's1', 'dir': '/Users/me/p', 'end': 0},
        {'id': 8, 'title': 'claude', 'kind': 'claude', 'session': 's2', 'dir': '/Users/me/q', 'end': 0},
      ],
      'term.attach': {'end': 0},
      'chat.recent': [
        {'id': 'c1', 'title': 'Fix the lid', 'mtime': now, 'dir': '/Users/me/p'},
      ],
    });
    final terms = Terms(link);
    await tester.pumpWidget(MaterialApp(
      home: Home(link: link, terms: terms, macs: const [], onSwitch: (_) {}, onAddMac: () {}, onLock: () {}, onUnpair: () {}, onRename: (_, _) async {}, onForget: (_) async {}),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(terms.sessions, hasLength(2));
    // Visible, not just in the tree: it once laid out 0 px wide over the sessions.
    expect(find.text('New session').hitTestable(), findsOneWidget);
    expect(find.text('Fix the lid').hitTestable(), findsOneWidget);
  });

  testWidgets('…and when the Mac connects after the page is up', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final link = FakeLink({
      'term.list': [
        {'id': 7, 'title': 'claude', 'kind': 'claude', 'session': 's1', 'dir': '/Users/me/p', 'end': 0},
        {'id': 8, 'title': 'claude', 'kind': 'claude', 'session': 's2', 'dir': '/Users/me/q', 'end': 0},
      ],
      'term.attach': {'end': 0},
      'chat.recent': [
        {'id': 'c1', 'title': 'Fix the lid', 'mtime': now, 'dir': '/Users/me/p'},
      ],
    });
    link
      ..state = LinkState.connecting
      ..epoch = 0;
    final terms = Terms(link);
    await tester.pumpWidget(MaterialApp(
      home: Home(link: link, terms: terms, macs: const [], onSwitch: (_) {}, onAddMac: () {}, onLock: () {}, onUnpair: () {}, onRename: (_, _) async {}, onForget: (_) async {}),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    link
      ..state = LinkState.online
      ..epoch = 1
      ..notifyListeners();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(terms.sessions, hasLength(2));
    // Visible, not just in the tree: it once laid out 0 px wide over the sessions.
    expect(find.text('New session').hitTestable(), findsOneWidget);
    expect(find.text('Fix the lid').hitTestable(), findsOneWidget, reason: 'calls: ${link.calls}');
  });

  testWidgets('with just one session open, the app opens it instead of the recent page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final link = FakeLink({
      'term.list': [
        {'id': 7, 'title': 'claude', 'kind': 'claude', 'session': 's1', 'dir': '/Users/me/p', 'end': 0},
      ],
      'term.attach': {'end': 0},
      'chat.recent': [],
    });
    final terms = Terms(link);
    await tester.pumpWidget(MaterialApp(
      home: Home(link: link, terms: terms, macs: const [], onSwitch: (_) {}, onAddMac: () {}, onLock: () {}, onUnpair: () {}, onRename: (_, _) async {}, onForget: (_) async {}),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Mac · ~/p'), findsOneWidget); // the session's top bar
    expect(find.text('New session'), findsNothing);
  });
}
