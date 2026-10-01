// Terminal tabs. The shells live on the Mac and outlive the connection: each
// tab remembers the byte offset it has seen and resumes from there.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../net/link.dart';

class TermTab {
  TermTab(this.id, this.title) {
    _dec = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_TermSink(terminal));
  }

  final int id;
  String title;
  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();
  int next = 0; // next output byte offset we expect
  bool exited = false;
  int replayUntil = 0; // output below this offset was already answered once
  bool _replaying = false;
  late final ByteConversionSink _dec;
  Timer? _resize;

  void note(String s) => terminal.write('\r\n\x1b[2m$s\x1b[0m\r\n');
}

class _TermSink implements Sink<String> {
  final Terminal t;
  _TermSink(this.t);
  @override
  void add(String s) => t.write(s);
  @override
  void close() {}
}

class Terms extends ChangeNotifier {
  Terms(this.link) {
    link.addListener(_onLink);
    _sub = link.events.listen(_onEvent);
    _onLink();
  }

  final Link link;
  final tabs = <TermTab>[];
  int active = 0;
  bool ctrl = false, alt = false; // one-shot modifiers from the key bar
  int _epoch = 0;
  bool _syncing = false;
  late final StreamSubscription _sub;

  TermTab? get current => tabs.isEmpty ? null : tabs[active.clamp(0, tabs.length - 1)];

  void _onLink() {
    if (link.online && link.epoch != _epoch) {
      _epoch = link.epoch;
      _sync();
    }
  }

  /// After every (re)connect: adopt the Mac's terminals and resume each one.
  Future<void> _sync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final list = (await link.call('term.list') as List).cast<Map>();
      final alive = {for (final m in list) (m['id'] as num).toInt(): m};
      for (final t in tabs) {
        if (!t.exited && !alive.containsKey(t.id)) {
          t.exited = true;
          t.note('[this terminal ended on the Mac]');
        }
      }
      final known = {for (final t in tabs) t.id};
      for (final m in list) {
        final id = (m['id'] as num).toInt();
        if (!known.contains(id)) tabs.add(_make(id, m['title'] as String? ?? ''));
      }
      // Output frames can arrive before the attach reply, so take the replay
      // boundary from the list.
      for (final t in tabs) {
        final end = alive[t.id]?['end'];
        if (end is num) t.replayUntil = end.toInt();
      }
      if (tabs.isEmpty) {
        await open();
      } else {
        for (final t in tabs) {
          if (!t.exited) _attach(t);
        }
      }
      notifyListeners();
    } catch (_) {
      // the next reconnect retries
    } finally {
      _syncing = false;
    }
  }

  TermTab _make(int id, String title) {
    final t = TermTab(id, title.isEmpty ? 'shell' : title);
    t.terminal.onOutput = (s) => _input(t, s);
    t.terminal.onTitleChange = (s) {
      final title = s.trim();
      if (title.isNotEmpty && title != t.title) {
        t.title = title;
        notifyListeners();
      }
    };
    t.terminal.onBell = () => HapticFeedback.lightImpact();
    t.terminal.onResize = (w, h, _, _) {
      t._resize?.cancel();
      t._resize = Timer(const Duration(milliseconds: 120), () {
        if (!t.exited) {
          link.call('term.resize', {'id': t.id, 'cols': w, 'rows': h}).ignore();
        }
      });
    };
    link.termOut[id] = (off, data) => _output(t, off, data);
    return t;
  }

  void _output(TermTab t, int off, Uint8List data) {
    if (off > t.next) {
      if (t.next > 0) t.note('… some output was skipped …');
      t.next = off;
    }
    var d = data;
    if (off < t.next) {
      final skip = t.next - off;
      if (skip >= d.length) return;
      d = Uint8List.sublistView(d, skip);
    }
    t.next += d.length;
    // Replayed output may contain queries (cursor position, device attributes)
    // the shell already got answers to: don't answer them twice.
    t._replaying = t.next <= t.replayUntil;
    t._dec.add(d);
    t._replaying = false;
  }

  void _input(TermTab t, String s) {
    if (t.exited || t._replaying) return;
    var data = s;
    if (ctrl || alt) {
      if (ctrl && data.length == 1) data = String.fromCharCode(ctrlCode(data.codeUnitAt(0)));
      if (alt) data = '\x1b$data';
      ctrl = alt = false;
      notifyListeners();
    }
    if (!link.sendInput(t.id, utf8.encode(data))) HapticFeedback.heavyImpact();
  }

  static int ctrlCode(int c) {
    if (c >= 0x61 && c <= 0x7a) return c - 0x60; // a-z
    if (c >= 0x40 && c <= 0x5f) return c - 0x40; // @ A-Z [ \ ] ^ _
    if (c == 0x20) return 0;
    if (c == 0x3f) return 0x7f;
    return c;
  }

  Future<void> _attach(TermTab t) async {
    try {
      final info = await link.call('term.attach', {
        'id': t.id,
        'from': t.next,
        'cols': t.terminal.viewWidth,
        'rows': t.terminal.viewHeight,
      }) as Map;
      final end = (info['end'] as num).toInt();
      if (end > t.replayUntil) t.replayUntil = end;
    } on RpcError catch (e) {
      if (e.code == 'gone') {
        t.exited = true;
        t.note('[this terminal ended on the Mac]');
        notifyListeners();
      }
    }
  }

  Future<void> open({String? dir}) async {
    final cur = current?.terminal;
    final info = await link.call('term.open', {
      'dir': ?dir,
      'cols': cur?.viewWidth ?? 80,
      'rows': cur?.viewHeight ?? 24,
    }) as Map;
    final t = _make((info['id'] as num).toInt(), '');
    tabs.add(t);
    active = tabs.length - 1;
    notifyListeners();
    await _attach(t);
  }

  void select(int i) {
    active = i;
    notifyListeners();
  }

  Future<void> close(TermTab t) async {
    if (!t.exited) {
      try {
        await link.call('term.close', {'id': t.id});
      } catch (_) {}
    }
    link.termOut.remove(t.id);
    final i = tabs.indexOf(t);
    tabs.remove(t);
    if (active >= i && active > 0) active--;
    notifyListeners();
  }

  void rename(TermTab t, String title) {
    t.title = title;
    link.call('term.rename', {'id': t.id, 'title': title}).ignore();
    notifyListeners();
  }

  void _onEvent((String, dynamic) e) {
    if (e.$1 != 'term.exit') return;
    final p = e.$2 as Map;
    final id = (p['id'] as num).toInt();
    for (final t in tabs) {
      if (t.id == id && !t.exited) {
        t.exited = true;
        t.note('[process exited with code ${p['code']}]');
        notifyListeners();
      }
    }
  }

  /// Types text into the active terminal as if pasted (bracketed paste aware).
  void paste(String text) {
    final t = current;
    if (t == null || t.exited) return;
    t.terminal.paste(text);
  }

  /// Sends text raw, e.g. a command composed in the editor sheet.
  void type(String text) {
    final t = current;
    if (t == null || t.exited) return;
    if (!link.sendInput(t.id, utf8.encode(text))) HapticFeedback.heavyImpact();
  }

  void toggleCtrl() {
    ctrl = !ctrl;
    notifyListeners();
  }

  void toggleAlt() {
    alt = !alt;
    notifyListeners();
  }

  void key(TerminalKey k) {
    final t = current;
    if (t == null) return;
    final c = ctrl, a = alt;
    if (c || a) {
      ctrl = alt = false;
      notifyListeners();
    }
    t.terminal.keyInput(k, ctrl: c, alt: a);
  }

  @override
  void dispose() {
    link.removeListener(_onLink);
    _sub.cancel();
    super.dispose();
  }
}
