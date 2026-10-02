import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/terminals/terminal_panel.dart';

const alt = '\x1b[?1049h';

Future<TermTab> pumpTerm(WidgetTester tester, {String mode = '', int lines = 30}) async {
  final t = TermTab(1, 'claude', kind: 'claude', session: 's', dir: '/');
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 400, height: 400, child: TermSurface(tab: t, fontSize: 13, onFocus: () {})),
    ),
  ));
  final out = StringBuffer(mode);
  for (var i = 0; i < lines; i++) {
    out.write('hello world line $i\r\n');
  }
  t.dec.add(utf8.encode(out.toString())); // the path the Mac's output takes
  await tester.pumpAndSettle();
  return t;
}

void main() {
  test('reattachLines repairs the full-screen buffer after it scrolls', () {
    final term = TermTab(1, 'c', kind: 'claude', session: 's', dir: '/').terminal;
    term.write(alt);
    for (var i = 0; i < 30; i++) {
      term.write('x $i\r\n');
    }
    final lines = term.buffer.lines;
    bool all() => lines.toList().every((l) => l.attached);
    expect(all(), isFalse, reason: 'xterm 4.0 bug: if fixed upstream, drop reattachLines');
    reattachLines(term);
    expect(all(), isTrue);
  });

  for (final (name, mode) in [('plain', ''), ('full-screen', alt), ('full-screen + mouse', '$alt\x1b[?1000h\x1b[?1006h')]) {
    testWidgets('a mouse drag selects on a Mac ($name)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final t = await pumpTerm(tester, mode: mode);
      final g = await tester.startGesture(const Offset(30, 30), kind: PointerDeviceKind.mouse);
      await g.moveTo(const Offset(150, 80));
      await tester.pump();
      await g.moveTo(const Offset(200, 120));
      await g.up();
      await tester.pumpAndSettle();
      final sel = t.controller.selection;
      expect(sel, isNotNull);
      expect(t.terminal.buffer.getText(sel!), contains('hello world line'));
      expect(find.text('Copy'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('a long-press drag past the top edge scrolls back and keeps its start', (tester) async {
    final t = await pumpTerm(tester, lines: 200);
    final g = await tester.startGesture(const Offset(100, 200));
    await tester.pump(const Duration(milliseconds: 600));
    final start = t.controller.selection!;
    await g.moveTo(const Offset(100, 2));
    await tester.pump(const Duration(seconds: 1));
    await g.moveTo(const Offset(110, 1)); // xterm's own update must not undo it
    await tester.pump(const Duration(milliseconds: 100));
    final sel = t.controller.selection!;
    await g.up();
    await tester.pumpAndSettle();
    expect(sel.begin.y, lessThan(start.begin.y - 30), reason: 'it scrolled up and selected on');
    expect(sel.end, start.end, reason: 'the word it started on stays the end');
  });

  testWidgets('a mouse drag past the bottom edge scrolls down', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final t = await pumpTerm(tester, lines: 200);
    await tester.drag(find.byType(TermSurface), const Offset(0, 300)); // scroll back first
    await tester.pumpAndSettle();
    final g = await tester.startGesture(const Offset(30, 200), kind: PointerDeviceKind.mouse);
    await g.moveTo(const Offset(30, 150));
    await tester.pump();
    final first = t.controller.selection!;
    await g.moveTo(const Offset(30, 399));
    await tester.pump(const Duration(seconds: 1));
    final sel = t.controller.selection!;
    await g.up();
    await tester.pumpAndSettle();
    expect(sel.end.y, greaterThan(first.end.y + 30));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('right click: Select all, then Copy puts the text on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    final t = await pumpTerm(tester);
    await tester.tapAt(const Offset(100, 100), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    expect(t.controller.selection, isNotNull);
    await tester.tapAt(const Offset(100, 100), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy').last);
    await tester.pumpAndSettle();
    expect(copied, startsWith('hello world line 0\nhello world line 1\n'));
    expect(copied, contains('hello world line 29'));
    expect(t.controller.selection, isNull);
  });
}
