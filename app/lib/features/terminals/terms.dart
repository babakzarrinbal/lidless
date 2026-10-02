// Terminals, grouped into Claude sessions. The shells live on the Mac (each
// in a holder process, see docs/architecture.md) and outlive the connection:
// each tab remembers the byte offset it has seen and resumes from there. A
// terminal opened anywhere (another phone, a laptop window) shows up here
// too: the Mac sends {"ev":"terms"} and [Terms] adopts it. A session is one folder with one Claude terminal and
// any number of plain shells, all tagged with the session id on the Mac.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'package:uniai/features/terminals/key_map.dart';
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/terminals/shell_info.dart';
import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/features/chat/chat.dart';


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
  bool _foreground = true; // the app is on screen
  SharedPreferences? _prefs;

  /// An agent stopped (finished, or asks something) with output not seen;
  /// [live] is its screen at that moment.
  void Function(TermTab t, LiveScreen live)? onUnread;

  /// The session came on screen: what it wrote is read.
  void Function(String session)? onRead;
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
    _seeUpTo(_viewing); // left: read up to here
    _viewing = id;
    _seeUpTo(id);
    _saveRead();
  }

  /// The app went to the background (false) or came back: what the session on
  /// screen writes meanwhile is news.
  set foreground(bool on) {
    if (on == _foreground) return;
    _seeUpTo(_viewing);
    _foreground = on;
    _seeUpTo(_viewing);
    _saveRead();
  }

  bool _onScreen(TermTab t) => _foreground && t.session == _viewing;

  void _seeUpTo(String? session) {
    if (session == null || !_foreground) return;
    for (final t in tabs) {
      if (t.session == session) t.readTo = t.next;
    }
    onRead?.call(session);
    _shareSeen();
  }

  Timer? _seenTimer;

  /// Tells the Mac what this phone has shown, so it is read on every phone.
  void _shareSeen() {
    if (!tabs.any((t) => !t.exited && min(t.readTo, t.next) > t.sentSeen)) return;
    _seenTimer ??= Timer(const Duration(seconds: 1), () {
      _seenTimer = null;
      for (final t in tabs) {
        final to = min(t.readTo, t.next);
        if (t.exited || to <= t.sentSeen) continue;
        t.sentSeen = to;
        link.call('term.seen', {'id': t.id, 'seen': to}).ignore(); // an older agent: unknown
      }
    });
  }

  /// Another phone showed [t] up to [to].
  void _seenElsewhere(TermTab t, int to) {
    if (to <= t.readTo) return;
    t.readTo = to;
    if (to > t.sentSeen) t.sentSeen = to;
    if (t.agent && !t.unread) onRead?.call(t.session); // its notification goes
  }

  String get _readKey => 'termRead:${link.pairing.room}';

  /// Read offsets survive the app: a Claude that finished while it was closed
  /// still shows as unread.
  void _saveRead() {
    _prefs?.setString(_readKey, jsonEncode({for (final t in tabs) '${t.id}': t.readTo}));
  }

  Future<Map<String, dynamic>> _loadRead() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      return (jsonDecode(_prefs!.getString(_readKey) ?? '{}') as Map).cast<String, dynamic>();
    } catch (_) {
      return const {};
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
      final read = synced ? const <String, dynamic>{} : await _loadRead();
      final alive = _apply(list, read);
      // Output frames can arrive before the attach reply, so take the replay
      // boundary from the list.
      for (final t in tabs) {
        final end = alive[t.id]?['end'];
        if (end is num) t.replayUntil = end.toInt();
        t.parked = alive[t.id]?['parked'] == true;
        final seen = alive[t.id]?['seen'];
        if (seen is num) _seenElsewhere(t, seen.toInt());
      }
      for (final t in tabs) {
        if (!t.exited) _attach(t);
      }
      synced = true;
      _synced = _epoch;
      _seeUpTo(_viewing);
      _saveRead();
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

  /// Marks the tabs the Mac no longer has as ended and adopts the ones it has
  /// that the phone does not; the Mac's terminals by id.
  Map<int, Map> _apply(List<Map> list, Map<String, dynamic> read) {
    final alive = {for (final m in list) (m['id'] as num).toInt(): m};
    for (final t in tabs) {
      if (!t.exited && !alive.containsKey(t.id)) {
        t.exited = true;
        t.settle?.cancel();
        t.working = false;
        t.note('[this terminal ended on the Mac]');
      }
    }
    final known = {for (final t in tabs) t.id};
    for (final m in list) {
      final id = (m['id'] as num).toInt();
      final session = m['session'] as String? ?? '';
      if (known.contains(id) || session.isEmpty) continue; // not one of ours
      final t = _make(id, m['title'] as String? ?? '',
          kind: m['kind'] as String? ?? 'shell', session: session, dir: m['dir'] as String? ?? '');
      // Read up to where the phone last showed it; one never shown is read.
      final end = (m['end'] as num?)?.toInt() ?? 0;
      t.readTo = min((read['$id'] as num?)?.toInt() ?? end, end);
      t.replayUntil = end;
      t.parked = m['parked'] == true;
      t.fresh = true;
      tabs.add(t);
    }
    return alive;
  }

  bool _refreshing = false, _again = false;

  /// The Mac's terminals changed (one opened or ended, on any device): adopt
  /// and attach the new ones; the others carry on as they are.
  Future<void> _refresh() async {
    if (!synced || _syncing || _synced != _epoch) return; // the sync after a connect covers it
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _again = false;
        final list = (await link.call('term.list') as List).cast<Map>();
        if (_synced != _epoch) return; // reconnected meanwhile: that sync covers it
        final before = {for (final t in tabs) t.id};
        _apply(list, const {});
        for (final t in tabs.where((t) => !before.contains(t.id) && !t.exited).toList()) {
          _attach(t);
        }
        notifyListeners();
      } while (_again);
    } catch (_) {
      // Offline or busy: the next event or reconnect brings it.
    } finally {
      _refreshing = false;
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
      t.shown = true;
      t.resize?.cancel();
      t.resize = Timer(const Duration(milliseconds: 120), () {
        if (!t.exited) {
          t.redrawUntil = DateTime.now().add(_redraw);
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
    final prev = t.next;
    t.next += d.length;
    // Replayed output may contain queries (cursor position, device attributes)
    // the shell already got answers to: don't answer them twice.
    final catchUp = t.next <= t.replayUntil;
    t.replaying = catchUp;
    t.dec.add(d);
    t.replaying = false;
    // An adopted terminal's replay is old; after a reconnect, what came
    // meanwhile is news.
    final old = t.fresh && t.next <= t.replayUntil;
    if (!old) t.fresh = false;
    if (_onScreen(t) || t.parked) {
      t.readTo = t.next;
      _shareSeen();
    }
    if (!t.agent || old || t.parked) return;
    final now = DateTime.now();
    // A redraw after a resize (on any device) is the same screen again,
    // unless Claude's status line says it started working meanwhile.
    if (!t.working && now.isBefore(t.redrawUntil) && LiveScreen.of(t.terminal).status == null) {
      if (t.readTo >= prev) t.readTo = t.next;
      return;
    }
    // An echo of what was typed is not work.
    if (!t.working && now.difference(t.typed) < const Duration(milliseconds: 400)) return;
    _busy(t, prev);
    // What came while this phone was away arrives in one burst, too fast to
    // catch the status line: count it as work.
    if (catchUp) t.sawWork = true;
  }

  static const _redraw = Duration(milliseconds: 1500);

  /// Output keeps an agent working; two quiet seconds with no spinner on its
  /// screen and it has stopped.
  void _busy(TermTab t, int prev) {
    t.settle?.cancel();
    t.settle = Timer(const Duration(seconds: 2), () => _settled(t));
    final now = DateTime.now();
    if (!t.working) {
      t.working = true;
      t.told = false;
      t.sawWork = false;
      t.readAtStart = t.readTo >= prev;
      t.sampled = DateTime(0);
      notifyListeners();
    }
    if (!t.sawWork && now.difference(t.sampled) > const Duration(milliseconds: 300)) {
      t.sampled = now;
      t.sawWork = LiveScreen.of(t.terminal).status != null;
    }
  }

  void _settled(TermTab t) {
    if (t.exited || !tabs.contains(t)) return;
    final live = LiveScreen.of(t.terminal);
    if (live.status != null && !live.asking) {
      t.settle = Timer(const Duration(seconds: 2), () => _settled(t));
      return;
    }
    t.working = false;
    // Claude shows a status line while it works. Output without one (a
    // laptop typing, a focus redraw) is not an answer to tell about.
    if (t.kind == 'claude' && !t.sawWork && !live.asking) {
      if (t.readAtStart) t.readTo = t.next;
      notifyListeners();
      return;
    }
    notifyListeners();
    if (t.unread && !t.told) {
      t.told = true;
      onUnread?.call(t, live);
    }
  }

  /// A key pressed in a parked terminal: Home starts its Claude again.
  void Function(TermTab t)? onWake;

  /// Something was just typed into an agent: it is about to work. Until then
  /// the app counts as busy, so leaving it right away keeps the link up
  /// (Android only lets the keep-alive service start while the app shows).
  bool get expecting => _expectTimer?.isActive ?? false;

  static const _expect = Duration(seconds: 30);
  Timer? _expectTimer;

  void _typedInto(TermTab t) {
    t.typed = DateTime.now();
    if (!t.agent) return;
    final was = expecting;
    _expectTimer?.cancel();
    _expectTimer = Timer(_expect, notifyListeners);
    if (!was) notifyListeners();
  }

  void _input(TermTab t, String s) {
    if (t.exited || t.replaying) return;
    _typedInto(t);
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
      final m = cmdKeys[c];
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

  Future<void> _attach(TermTab t) async {
    try {
      final info = await link.call('term.attach', {
        'id': t.id,
        'from': t.next,
        // A tab never on screen has the emulator's 80x24, which would shrink
        // the Mac's terminal for everyone (0: keep the size).
        'cols': t.shown ? t.terminal.viewWidth : 0,
        'rows': t.shown ? t.terminal.viewHeight : 0,
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
    final id = (info['id'] as num).toInt();
    // The Mac's "terms" event can bring it in first.
    final had = tabs.where((t) => t.id == id).firstOrNull;
    final t = had ?? _make(id, info['title'] as String? ?? '', kind: kind, session: session, dir: info['dir'] as String? ?? dir);
    if (had == null) tabs.add(t);
    if (kind == 'shell') {
      _activeShell[session] = tabs.where((x) => x.session == session && !x.agent).length - 1;
    }
    notifyListeners();
    if (had == null) await _attach(t);
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
    t.settle?.cancel();
    final s = session(t.session);
    final i = s?.shells.indexOf(t) ?? -1;
    tabs.remove(t);
    final a = _activeShell[t.session];
    if (i >= 0 && a != null && a >= i && a > 0) _activeShell[t.session] = a - 1;
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
    if (e.$1 == 'terms') {
      _refresh();
      return;
    }
    if (e.$1 == 'term.size' || e.$1 == 'term.seen') {
      final p = e.$2 as Map;
      final t = tabs.where((t) => t.id == (p['id'] as num).toInt()).firstOrNull;
      if (t == null) return;
      if (e.$1 == 'term.size') {
        t.redrawUntil = DateTime.now().add(_redraw);
      } else {
        _seenElsewhere(t, (p['seen'] as num).toInt());
        _saveRead();
        notifyListeners();
      }
      return;
    }
    if (e.$1 != 'term.exit') return;
    final p = e.$2 as Map;
    final id = (p['id'] as num).toInt();
    for (final t in tabs) {
      if (t.id == id && !t.exited) {
        t.exited = true;
        t.settle?.cancel();
        t.working = false;
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
    _typedInto(t);
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

  void key(TermTab? t, TerminalKey k, {bool shift = false}) {
    if (t == null) return;
    final c = ctrl, a = alt, m = cmd;
    _clearMods();
    final seq = m ? cmdArrows[k] : (a && !c ? optArrows[k] : null);
    if (seq != null) return type(t, seq);
    t.terminal.keyInput(k, ctrl: c, alt: a, shift: shift);
  }

  @override
  void dispose() {
    _seeUpTo(_viewing);
    _saveRead();
    for (final t in tabs) {
      t.settle?.cancel();
    }
    _seenTimer?.cancel();
    _expectTimer?.cancel();
    link.removeListener(_onLink);
    _sub.cancel();
    super.dispose();
  }
}
