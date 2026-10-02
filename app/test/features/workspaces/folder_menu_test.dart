import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uniai/features/workspaces/pins.dart';
import 'package:uniai/features/workspaces/folder_menu.dart';
import 'package:uniai/features/workspaces/workspaces.dart';

import '../../support/fakes.dart';

void main() {
  test('forgetRecentDir takes one folder off this Mac only', () async {
    SharedPreferences.setMockInitialValues({
      'recentDirs:m': ['/a', '/b'],
      'recentDirs:other': ['/a'],
    });
    final p = await SharedPreferences.getInstance();
    await forgetRecentDir(p, 'm', '/a');
    expect(p.getStringList('recentDirs:m'), ['/b']);
    expect(p.getStringList('recentDirs:other'), ['/a']);
  });

  testWidgets('long press or right click on a folder offers Remove from list', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final removed = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorkspaceList(
          link: FakeLink({}),
          prefs: prefs,
          mac: 'm',
          sessions: const [],
          pins: Pins('m', prefs: prefs),
          dirs: const ['/Users/me/proj'],
          tile: (s) => Text(s.id),
          onNew: (_) {},
          onResume: (_, _) {},
          onRemove: removed.add,
          load: (_) async => [],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('proj'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from list'));
    await tester.pumpAndSettle();
    expect(removed, ['/Users/me/proj']);

    await tester.tap(find.text('proj'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Remove from list'), findsOneWidget);
  });
}
