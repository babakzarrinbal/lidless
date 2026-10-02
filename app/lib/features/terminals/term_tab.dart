// One terminal on the Mac as the phone holds it: the emulator, how far its
// output has been read, and the bookkeeping [Terms] keeps for its activity
// (working, unread). The fields without a comment of their own are [Terms]'
// state for this tab; only [Terms] writes them.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:xterm/xterm.dart';

import 'package:uniai/features/chat/chat.dart';

class TermTab {
  TermTab(this.id, this.title, {required this.kind, required this.session, required this.dir}) {
    dec = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_TermSink(terminal));
  }

  final int id;
  final String kind; // the session's agent ('claude', 'copilot') or 'shell'
  final String session, dir;
  String title;
  final terminal = Terminal(maxLines: 10000, mouseHandler: const WheelFix());
  final controller = TerminalController();
  final chat = ChatLog(); // the agent's transcript, read on demand
  int next = 0; // next output byte offset we expect
  bool exited = false;
  bool parked = false; // an older app quit its idle Claude; [Terms.unpark] brings it back
  int readTo = 0; // output below this offset was on screen
  int replayUntil = 0; // output below this offset was already answered once
  bool working = false; // the agent is thinking or writing
  bool replaying = false;
  bool fresh = false; // just adopted: its replay is old news
  bool told = false; // [Terms.onUnread] was called for this stop
  bool shown = false; // laid out on screen once: its size is real, not 80x24
  bool sawWork = false; // this burst showed the agent's working status
  bool readAtStart = false; // all was read when this burst began
  int sentSeen = 0; // the read offset last shared with the other devices
  DateTime typed = DateTime(0), redrawUntil = DateTime(0), sampled = DateTime(0);
  late final ByteConversionSink dec;
  Timer? resize, settle;

  bool get agent => kind != 'shell';

  /// Output bytes the phone has not shown.
  int get unseen => max(0, next - readTo);

  /// The agent wrote more than a cursor blink while its session was not shown.
  bool get unread => agent && unseen > 512;

  void note(String s) => terminal.write('\r\n\x1b[2m$s\x1b[0m\r\n');
}

/// xterm 4.0 reports the mouse wheel as buttons 68/69 (shift + wheel); real
/// terminals send 64/65, and full-screen apps such as Copilot ignore the
/// rest. Without this a swipe scrolls nothing in those apps.
///
/// Its position is wrong too: xterm measures the finger from the phone's
/// screen, not the terminal, so it lands rows below the app (under its input
/// box, or off the screen) and the app scrolls nothing. The wheel goes to the
/// middle of the screen instead, where an agent's conversation is.
class WheelFix implements TerminalMouseHandler {
  const WheelFix();

  @override
  String? call(TerminalMouseEvent e) {
    if (!e.button.isWheel) return defaultMouseHandler(e);
    final mode = e.state.mouseMode;
    if (e.buttonState != TerminalMouseButtonState.down || mode == MouseMode.none || mode == MouseMode.clickOnly) {
      return null;
    }
    final id = e.button.id - 4, x = e.state.viewWidth ~/ 2 + 1, y = e.state.viewHeight ~/ 2 + 1;
    if (e.state.mouseReportMode == MouseReportMode.sgr) return '\x1b[<$id;$x;${y}M';
    return '\x1b[M${String.fromCharCode(32 + id)}${String.fromCharCode(32 + x)}${String.fromCharCode(32 + y)}';
  }
}

class _TermSink implements Sink<String> {
  final Terminal t;
  _TermSink(this.t);
  @override
  void add(String s) => t.write(s);
  @override
  void close() {}
}
