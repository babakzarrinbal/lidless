import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniai/features/terminals/select_handles.dart';
import 'package:uniai/features/terminals/select_range.dart';
import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/terminals/terminal_panel.dart';
import 'package:xterm/xterm.dart';

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

/// The centre of cell [x] on the [row]th line on screen, in global pixels.
Offset cell(WidgetTester tester, int x, int row) {
  final r = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
  final top = r.getCellOffset(const Offset(10, 10)).y;
  final o = r.getOffset(CellOffset(x, top + row));
  return r.localToGlobal(o + Offset(r.cellSize.width / 2, r.lineHeight / 2));
}

String selected(TermTab t) => t.terminal.buffer.getText(t.controller.selection!).trim();

/// A mouse click at [at] with an explicit time, so clicks count as double
/// and triple clicks (test gestures all start at time zero).
Future<void> click(WidgetTester tester, Offset at, int ms) async {
  final p = TestPointer(++_mice, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(p.addPointer(location: at));
  await tester.sendEventToBinding(p.down(at, timeStamp: Duration(milliseconds: ms)));
  await tester.sendEventToBinding(p.up(timeStamp: Duration(milliseconds: ms + 30)));
  await tester.sendEventToBinding(p.removePointer());
  await tester.pump();
}

var _mice = 10;

/// A widget test on a Mac.
void macTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
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

  test('spans: a line takes the rows it wrapped onto; shift keeps the far end', () {
    final term = Terminal(maxLines: 100)..resize(10, 5);
    term.write('${'a' * 15}\r\nbb cc');
    final b = term.buffer;
    final line = spanAt(b, const CellOffset(2, 1), SelUnit.line);
    expect(b.getText(BufferRangeLine(line.begin, line.end)).replaceAll('\n', ''), 'a' * 15);
    final word = spanAt(b, const CellOffset(4, 2), SelUnit.word);
    expect(b.getText(BufferRangeLine(word.begin, word.end)), 'cc');
    final sel = BufferRangeLine(const CellOffset(0, 0), const CellOffset(5, 2));
    expect(farEnd(sel, const CellOffset(1, 0), 10), const CellOffset(5, 2));
    expect(farEnd(sel, const CellOffset(4, 2), 10), const CellOffset(0, 0));
  });

  for (final (name, mode) in [('plain', ''), ('full-screen', alt), ('full-screen + mouse', '$alt\x1b[?1000h\x1b[?1006h')]) {
    macTest('a mouse drag selects the cells it crosses ($name)', (tester) async {
      final t = await pumpTerm(tester, mode: mode);
      final g = await tester.startGesture(cell(tester, 0, 1) - const Offset(3, 0), kind: PointerDeviceKind.mouse);
      await g.moveTo(cell(tester, 2, 1));
      await tester.pump();
      await g.moveTo(cell(tester, 5, 2) - const Offset(3, 0));
      await g.up();
      await tester.pumpAndSettle();
      expect(selected(t), startsWith('hello world line'));
      expect(selected(t), endsWith('\nhello'));
      expect(find.text('Copy'), findsOneWidget);
      expect(find.byType(SelHandle), findsNothing, reason: 'no handles for a mouse');
    });
  }

  macTest('double click selects a word, triple click the line, a click clears', (tester) async {
    final t = await pumpTerm(tester);
    final at = cell(tester, 7, 1);
    await click(tester, at, 1000);
    expect(t.controller.selection, isNull, reason: 'one click selects nothing');
    await click(tester, at, 1100);
    expect(selected(t), 'world');
    await click(tester, at, 1200);
    expect(selected(t), startsWith('hello world line'));
    expect(selected(t), isNot(contains('\n')));
    await click(tester, at, 3000);
    expect(t.controller.selection, isNull);
  });

  macTest('shift+click moves the nearer end of the selection', (tester) async {
    final t = await pumpTerm(tester);
    await click(tester, cell(tester, 7, 1), 1000);
    await click(tester, cell(tester, 7, 1), 1100); // "world"
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await click(tester, cell(tester, 5, 3) - const Offset(3, 0), 5000);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(selected(t), startsWith('world line'));
    expect(selected(t), endsWith('\nhello'));
    expect(selected(t).split('\n'), hasLength(3));
  });

  testWidgets('a long press selects a word; the handles move either end', (tester) async {
    final t = await pumpTerm(tester);
    final g = await tester.startGesture(cell(tester, 7, 3));
    await tester.pump(const Duration(milliseconds: 450));
    await g.up();
    await tester.pumpAndSettle();
    expect(selected(t), 'world');
    expect(find.byType(SelHandle), findsNWidgets(2));
    // The end handle hangs under "world": drag it two lines down.
    final end = tester.getTopLeft(find.byKey(const ValueKey('sel-end'))) + const Offset(22, 20);
    final r = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
    await tester.dragFrom(end, Offset(0, 2 * r.lineHeight));
    await tester.pumpAndSettle();
    expect(selected(t), startsWith('world line'));
    expect(selected(t).split('\n'), hasLength(3));
    expect(selected(t).split('\n').last, 'hello world');
    // A tap clears it, and the handles go.
    await tester.tapAt(cell(tester, 2, 10));
    await tester.pumpAndSettle();
    expect(t.controller.selection, isNull);
    expect(find.byType(SelHandle), findsNothing);
    await tester.pump(const Duration(milliseconds: 400)); // xterm's double-tap timer
  });

  testWidgets('a long-press drag past the top edge scrolls back and keeps its start', (tester) async {
    final t = await pumpTerm(tester, lines: 200);
    final g = await tester.startGesture(const Offset(100, 200));
    await tester.pump(const Duration(milliseconds: 600));
    final start = t.controller.selection!;
    await g.moveTo(const Offset(100, 2));
    await tester.pump(const Duration(seconds: 1));
    await g.moveTo(const Offset(110, 1));
    await tester.pump(const Duration(milliseconds: 100));
    final sel = t.controller.selection!;
    await g.up();
    await tester.pumpAndSettle();
    expect(sel.begin.y, lessThan(start.begin.y - 30), reason: 'it scrolled up and selected on');
    expect(sel.end, start.end, reason: 'the word it started on stays the end');
  });

  macTest('a mouse drag past the bottom edge scrolls down', (tester) async {
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
    expect(sel.end.y, greaterThan(first.end.y + 20));
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
