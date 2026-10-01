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
import 'chat.dart';

class TermTab {
  TermTab(this.id, this.title, {required this.kind, required this.session, required this.dir}) {
    _dec = const Utf8Decoder(allowMalformed: true)
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
  bool parked = false; // its Claude quit while idle; [Terms.unpark] brings it back
  int unseen = 0; // output bytes since the session was last on screen
  int replayUntil = 0; // output below this offset was already answered once
  bool _replaying = false;
  late final ByteConversionSink _dec;
  Timer? _resize;

  bool get agent => kind != 'shell';

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
  // One-shot modifiers from the key bar: ⌃ control, ⌥ option (meta), ⌘ command.
  bool ctrl = false, alt = false, cmd = false;
  bool synced = false; // the Mac's list has been read at least once
  String? _viewing; // the session on screen
  int _epoch = 0, _synced = -1; // the link's connection; the one last synced
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

  /// The session on screen: what it writes is read.
  set viewing(String? id) {
    if (id == _viewing) return;
    _viewing = id;
    for (final t in tabs) {
      if (t.session == id) t.unseen = 0;
    }
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
        t.parked = alive[t.id]?['parked'] == true;
      }
      for (final t in tabs) {
        if (!t.exited) _attach(t);
      }
      synced = true;
      _synced = _epoch;
      notifyListeners();
    } catch (_) {
      // Just connected, the Mac is still busy: try again shortly.
    } finally {
      _syncing = false;
      if (_synced != _epoch) {
        Timer(const Duration(seconds: 2), () {
          if (link.online && link.epoch == _epoch && _synced != _epoch) _sync();
        });
      }
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
    if (t.agent && !t._replaying && t.session != _viewing) {
      final was = t.unread;
      t.unseen += d.length;
      if (!was && t.unread) notifyListeners();
    }
    t._replaying = false;
  }

  /// A key pressed in a parked terminal: Home starts its Claude again.
  void Function(TermTab t)? onWake;

  void _input(TermTab t, String s) {
    if (t.exited || t._replaying) return;
    if (t.parked) return onWake?.call(t);
    var data = s;
    if (cmd) {
      _clearMods();
      final c = data.toLowerCase();
      if (c == 'v') {
        Clipboard.getData(Clipboard.kTextPlain).then((d) {
          final txt = d?.text;
          if (txt != null && txt.isNotEmpty) paste(t, txt);
        });
        return;
      }
      // What Terminal.app does with ⌘ shortcuts, as the shell understands them.
      final m = _cmdKeys[c];
      if (m == null) {
        HapticFeedback.heavyImpact();
        return;
      }
      data = m;
    } else if (ctrl || alt) {
      if (ctrl && data.length == 1) data = String.fromCharCode(ctrlCode(data.codeUnitAt(0)));
      if (alt) data = '\x1b$data';
      _clearMods();
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
    String? shell, // a path from [shellInfo]; null: the Mac's default
  }) async {
    final like = sizeLike?.terminal;
    final info = await link.call('term.open', {
      'dir': dir,
      'kind': kind,
      'session': session,
      'cmd': ?cmd,
      'shell': ?shell,
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
  Future<String> start(String dir, String flags, {String tool = 'claude', String? shell}) async {
    final r = Random.secure();
    final id = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await open(session: id, dir: dir, kind: tool, cmd: command(tool, flags), shell: shell);
    return id;
  }

  ShellInfo? _shells;
  int _shellsEpoch = -1;

  /// The shells the Mac offers and its default; null from an agent too old
  /// to choose.
  Future<ShellInfo?> shellInfo() async {
    if (_shells != null && _shellsEpoch == link.epoch) return _shells;
    try {
      _shells = ShellInfo.from(await link.call('shell.list') as Map);
      _shellsEpoch = link.epoch;
      return _shells;
    } on RpcError catch (e) {
      if (e.code == 'unknown') return null;
      rethrow;
    }
  }

  /// Makes [shell] (empty: the account's login shell) the Mac's default.
  Future<ShellInfo> setDefaultShell(String shell) async {
    _shells = ShellInfo.from(await link.call('shell.set', {'shell': shell}) as Map);
    _shellsEpoch = link.epoch;
    return _shells!;
  }

  /// What to type into the session's first shell; null for a plain shell.
  static String? command(String tool, String flags) {
    if (tool == 'cli') return flags.trim().isEmpty ? null : flags.trim();
    return flags.trim().isEmpty ? tool : '$tool ${flags.trim()}';
  }

  /// Ends every terminal of a session; the conversations Claude had open.
  Future<List<String>> closeSession(String id) async {
    final open = <String>[];
    for (final t in tabs.where((t) => t.session == id).toList()) {
      final c = await close(t);
      if (c != null) open.add(c);
    }
    _activeShell.remove(id);
    return open;
  }

  /// Ends a terminal (its Claude quits first and saves); the conversation
  /// that Claude had open, if any.
  Future<String?> close(TermTab t) async {
    String? conv;
    if (!t.exited) {
      try {
        final r = await link.call('term.close', {'id': t.id});
        if (r is Map && (r['conversation'] as String? ?? '').isNotEmpty) conv = r['conversation'] as String;
      } catch (_) {}
    }
    link.termOut.remove(t.id);
    final s = session(t.session);
    final i = s?.shells.indexOf(t) ?? -1;
    tabs.remove(t);
    final a = _activeShell[t.session];
    if (i >= 0 && a != null && a >= i && a > 0) _activeShell[t.session] = a - 1;
    notifyListeners();
    return conv;
  }

  /// Quits the session's Claude while it is idle, so the conversation is free
  /// for the laptop or another phone; the conversation, or null.
  Future<String?> park(Session s) async {
    final a = s.agent;
    if (a == null || a.exited || a.parked || a.kind != 'claude') return null;
    final live = LiveScreen.of(a.terminal);
    if (live.status != null || live.asking) return null; // working, or asking
    final r = await link.call('term.park', {'id': a.id}, const Duration(seconds: 10));
    final conv = r is Map ? r['conversation'] as String? ?? '' : '';
    if (conv.isEmpty) return null;
    a.parked = true;
    a.note('[Claude quit while you were away, so the laptop or another phone can pick this conversation up. '
        'It starts again when you come back or press a key.]');
    notifyListeners();
    return conv;
  }

  /// Starts a parked Claude again. [take] quits a Claude that opened the
  /// conversation elsewhere meanwhile; without it that is an RpcError 'busy'.
  Future<void> unpark(Session s, {bool take = false}) async {
    final a = s.agent;
    if (a == null || a.exited || !a.parked) return;
    await link.call('term.unpark', {'id': a.id, 'take': take}, const Duration(seconds: 15));
    a.parked = false;
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
    if (t.parked) return onWake?.call(t);
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

  void toggleCmd() {
    cmd = !cmd;
    notifyListeners();
  }

  void _clearMods() {
    if (!(ctrl || alt || cmd)) return;
    ctrl = alt = cmd = false;
    notifyListeners();
  }

  static const _cmdKeys = {
    'k': '\x0c', // clear the screen
    '.': '\x03', // interrupt
    'a': '\x01', // start of line
    'e': '\x05',
    'z': '\x1f', // readline undo
  };

  // Mac line editing: ⌘ jumps to the line's ends, ⌥ moves by word.
  static const _cmdArrows = {
    TerminalKey.arrowLeft: '\x01',
    TerminalKey.arrowRight: '\x05',
    TerminalKey.backspace: '\x15',
    TerminalKey.delete: '\x0b',
  };
  static const _optArrows = {
    TerminalKey.arrowLeft: '\x1bb',
    TerminalKey.arrowRight: '\x1bf',
    TerminalKey.backspace: '\x1b\x7f',
    TerminalKey.delete: '\x1bd',
  };

  void key(TermTab? t, TerminalKey k, {bool shift = false}) {
    if (t == null) return;
    final c = ctrl, a = alt, m = cmd;
    _clearMods();
    final seq = m ? _cmdArrows[k] : (a && !c ? _optArrows[k] : null);
    if (seq != null) return type(t, seq);
    t.terminal.keyInput(k, ctrl: c, alt: a, shift: shift);
  }

  @override
  void dispose() {
    link.removeListener(_onLink);
    _sub.cancel();
    super.dispose();
  }
}

/// The shells a Mac offers (/etc/shells) and the one new terminals get.
class ShellInfo {
  ShellInfo.from(Map m)
      : shells = [...((m['shells'] as List?) ?? const []).cast<String>()],
        def = m['default'] as String? ?? '',
        login = m['login'] as String? ?? '';
  final List<String> shells;
  final String def; // set from the phone; empty: the login shell
  final String login; // the account's shell

  String get current => def.isEmpty ? login : def;
}

/// "zsh" for "/bin/zsh".
String shellName(String path) => path.substring(path.lastIndexOf('/') + 1);
