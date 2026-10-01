import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:macremote/model/alerts.dart';
import 'package:macremote/model/terms.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_test.dart' show FakeLink;

void main() {
  testWidgets('a session works (green), stops unseen (blue, notified), is read once shown, and that survives a restart',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    FakeLink mac(int end) => FakeLink({
          'term.list': [
            {'id': 7, 'title': 'claude', 'kind': 'claude', 'session': 's1', 'dir': '/p', 'end': 0},
            {'id': 8, 'title': 'claude', 'kind': 'claude', 'session': 's2', 'dir': '/q', 'end': end},
          ],
          'term.attach': {'end': end},
        });
    final link = mac(0);
    final terms = Terms(link);
    final told = <String>[], read = <String>[];
    terms.onUnread = (t, _) => told.add(t.session);
    terms.onRead = read.add;
    await tester.pump(const Duration(milliseconds: 100));
    terms.viewing = 's1';
    Activity of(String id) => terms.session(id)!.activity;
    void say(int id, int off) => link.termOut[id]!(off, Uint8List.fromList(utf8.encode('x' * 600)));

    say(8, 0);
    expect(of('s2'), Activity.working);
    await tester.pump(const Duration(seconds: 3));
    expect(of('s2'), Activity.unread);
    expect(told, ['s2']);

    // What the session on screen writes is read.
    say(7, 0);
    await tester.pump(const Duration(seconds: 3));
    expect(of('s1'), Activity.read);
    expect(told, ['s2']);

    terms.viewing = 's2';
    expect(of('s2'), Activity.read);
    expect(read, contains('s2'));

    // With the app away, even the session on screen is news.
    terms.foreground = false;
    say(8, 600);
    await tester.pump(const Duration(seconds: 3));
    expect(of('s2'), Activity.unread);
    expect(told, ['s2', 's2']);

    // Restarted: the Mac's terminal went on; what the phone never showed is unread.
    terms.dispose();
    final link2 = mac(1200);
    final again = Terms(link2)..onUnread = (t, _) => told.add('again');
    await tester.pump(const Duration(milliseconds: 100));
    link2.termOut[8]!(0, Uint8List(1200)); // the replay
    await tester.pump(const Duration(seconds: 3));
    expect(again.session('s1')!.activity, Activity.read);
    expect(again.session('s2')!.activity, Activity.unread);
    expect(told, ['s2', 's2']); // old news: no notification
    again.dispose();
  });

  test('a notification shows the end of a long answer, cut at a word', () {
    expect(tail('short'), 'short');
    final t = tail('${'word ' * 200}the end.', 50);
    expect(t, startsWith('…'));
    expect(t, endsWith('the end.'));
    expect(t.length, lessThanOrEqualTo(51));
  });
}
