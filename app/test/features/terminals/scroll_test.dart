import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/terminals/terminal_panel.dart';

void main() {
  testWidgets('a read-only terminal scrolls back with a swipe', (tester) async {
    final t = TermTab(1, 'claude', kind: 'claude', session: 's', dir: '/');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: TermSurface(tab: t, fontSize: 13, onFocus: () {}),
        ),
      ),
    ));
    for (var i = 0; i < 300; i++) {
      t.terminal.write('line $i\r\n');
    }
    await tester.pumpAndSettle();
    final pos = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    final bottom = pos.pixels;
    expect(bottom, greaterThan(0));
    await tester.drag(find.byType(TermSurface), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(pos.pixels, lessThan(bottom));
  });

  testWidgets('a full-screen app (alt screen + mouse) gets wheel events from a swipe', (tester) async {
    final t = TermTab(1, 'claude', kind: 'claude', session: 's', dir: '/');
    final out = StringBuffer();
    t.terminal.onOutput = out.write;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: TermSurface(tab: t, fontSize: 13, onFocus: () {}),
        ),
      ),
    ));
    t.terminal.write('\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h');
    await tester.pumpAndSettle();
    await tester.drag(find.byType(TermSurface), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(out.toString(), contains('\x1b[<64;'));
  });
}
