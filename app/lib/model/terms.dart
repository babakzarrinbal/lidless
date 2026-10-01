// Terminals, grouped into Claude sessions. The shells live on the Mac and
// outlive the connection: each tab remembers the byte offset it has seen and
// resumes from there. A session is one folder with one Claude terminal and
// any number of plain shells, all tagged with the session id on the Mac.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../net/link.dart';

class TermTab {
  TermTab(this.id, this.title, {required this.kind, required this.session, required this.dir}) {
    _dec = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_TermSink(terminal));
  }

  final int id;
  final String kind; // the session's agent ('claude', 'copilot') or 'shell'
  final String session, dir;
  String title;
  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();
  int next = 0; // next output byte offset we expect
  bool exited = false;
  int replayUntil = 0; // output below this offset was already answered once
  bool _replaying = false;
  late final ByteConversionSink _dec;
  Timer? _resize;

  bool get agent => kind != 'shell';

  void note(String s) => terminal.write('\r\n\x1b[2m$s\x1b[0m\r\n');
}

/// The coding agents a session can run, by terminal kind.
/// 'cli' is a plain shell as the main window.
const tools = {'claude': 'Claude', 'copilot': 'Copilot', 'cli': 'Terminal'};

/// A view over the terminals that share a session id: one agent terminal
/// (Claude Code or Copilot) and any number of shells.
class Session {
  Session(this.id, this.dir);
  final String id, dir;
  TermTab? agent;
  final shells = <TermTab>[];

  String get tool => agent?.kind ?? 'claude';
  String get toolName => tools[tool] ?? tool;

  String get name {
    final parts = dir.split('/').where((s) => s.isNotEmpty);
    return parts.isEmpty ? '/' : parts.last;
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

class Terms extends ChangeNotifier {
  Terms(this.link) {
    link.addListener(_onLink);
    _sub = link.events.listen(_onEvent);
    _onLink();
  }

  final Link link;
  final tabs = <TermTab>[];
  final _activeShell = <String, int>{}; // session id -> shell tab index
  bool ctrl = false, alt = false; // one-shot modifiers from the key bar
  bool synced = false; // the Mac's list has been read at least once
  int _epoch = 0;
  bool _syncing = false;
  late final StreamSubscription _sub;

  /// Sessions in the order they were started.
  List<Session> get sessions {
    final m = <String, Session>{};
    for (final t in tabs) {
      final s = m.putIfAbsent(t.session, () => Session(t.session, t.dir));
      if (t.agent) {
        // A restarted agent replaces the one that ended.
        if (s.agent == null || s.agent!.exited) s.agent = t;
      } else {
        s.shells.add(t);
      }
    }
    return m.values.toList();
  }

  Session? session(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  TermTab? activeShell(Session s) =>
      s.shells.isEmpty ? null : s.shells[(_activeShell[s.id] ?? 0).clamp(0, s.shells.length - 1)];

  void selectShell(Session s, TermTab t) {
    _activeShell[s.id] = s.shells.indexOf(t);
    notifyListeners();
  }

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
        final session = m['session'] as String? ?? '';
        if (known.contains(id) || session.isEmpty) continue; // not one of ours
        tabs.add(_make(id, m['title'] as String? ?? '',
            kind: m['kind'] as String? ?? 'shell', session: session, dir: m['dir'] as String? ?? ''));
      }
      // Output frames can arrive before the attach reply, so take the replay
      // boundary from the list.
      for (final t in tabs) {
        final end = alive[t.id]?['end'];
        if (end is num) t.replayUntil = end.toInt();
      }
      for (final t in tabs) {
        if (!t.exited) _attach(t);
      }
      synced = true;
      notifyListeners();
    } catch (_) {
      // the next reconnect retries
    } finally {
      _syncing = false;
    }
  }

  TermTab _make(int id, String title,
      {required String kind, required String session, required String dir}) {
    final t = TermTab(id, title.isEmpty ? kind : title, kind: kind, session: session, dir: dir);
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

  /// Opens a terminal on the Mac. [cmd] is typed into the new shell first.
  Future<TermTab> open({
    required String session,
    required String dir,
    String kind = 'shell',
    String? cmd,
    TermTab? sizeLike,
  }) async {
    final like = sizeLike?.terminal;
    final info = await link.call('term.open', {
      'dir': dir,
      'kind': kind,
      'session': session,
      'cmd': ?cmd,
      'cols': like?.viewWidth ?? 80,
      'rows': like?.viewHeight ?? 24,
    }) as Map;
    final t = _make((info['id'] as num).toInt(), info['title'] as String? ?? '',
        kind: kind, session: session, dir: info['dir'] as String? ?? dir);
    tabs.add(t);
    if (kind == 'shell') {
      _activeShell[session] = tabs.where((x) => x.session == session && !x.agent).length - 1;
    }
    notifyListeners();
    await _attach(t);
    return t;
  }

  /// Starts a new session: [tool] (a key of [tools]) in [dir] with [flags].
  Future<String> start(String dir, String flags, {String tool = 'claude'}) async {
    final r = Random.secure();
    final id = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await open(session: id, dir: dir, kind: tool, cmd: command(tool, flags));
    return id;
  }

  /// What to type into the session's first shell; null for a plain shell.
  static String? command(String tool, String flags) {
    if (tool == 'cli') return flags.trim().isEmpty ? null : flags.trim();
    return flags.trim().isEmpty ? tool : '$tool ${flags.trim()}';
  }

  /// Ends every terminal of a session.
  Future<void> closeSession(String id) async {
    for (final t in tabs.where((t) => t.session == id).toList()) {
      await close(t);
    }
    _activeShell.remove(id);
  }

  Future<void> close(TermTab t) async {
    if (!t.exited) {
      try {
        await link.call('term.close', {'id': t.id});
      } catch (_) {}
    }
    link.termOut.remove(t.id);
    final s = session(t.session);
    final i = s?.shells.indexOf(t) ?? -1;
    tabs.remove(t);
    final a = _activeShell[t.session];
    if (i >= 0 && a != null && a >= i && a > 0) _activeShell[t.session] = a - 1;
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

  /// Types text into [t] as if pasted (bracketed paste aware).
  void paste(TermTab? t, String text) {
    if (t == null || t.exited) return;
    t.terminal.paste(text);
  }

  /// Sends text raw, e.g. a command composed in the editor sheet.
  void type(TermTab? t, String text) {
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

  void key(TermTab? t, TerminalKey k, {bool shift = false}) {
    if (t == null) return;
    final c = ctrl, a = alt;
    if (c || a) {
      ctrl = alt = false;
      notifyListeners();
    }
    t.terminal.keyInput(k, ctrl: c, alt: a, shift: shift);
  }

  @override
  void dispose() {
    link.removeListener(_onLink);
    _sub.cancel();
    super.dispose();
  }
}
