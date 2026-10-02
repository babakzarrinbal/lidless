// The home screen: the Mac list, drawer, session tabs and the current view.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/features/files/files.dart';
import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/terminals/terms.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/features/alerts/notify.dart';
import 'package:uniai/net/store.dart';
import 'package:uniai/features/devices/macs.dart';
import 'package:uniai/features/workspaces/folder_menu.dart';
import 'package:uniai/features/workspaces/new_session.dart';
import 'package:uniai/features/workspaces/pins.dart';
import 'package:uniai/app/session_view.dart';
import 'package:uniai/app/home_bar.dart';
import 'package:uniai/app/home_drawer.dart';
import 'package:uniai/app/home_recent.dart';
import 'package:uniai/app/home_status.dart';
import 'package:uniai/app/session_flows.dart';
import 'package:uniai/app/theme.dart';

/// The main screen: a side bar with the paired Macs and the Mac's sessions,
/// and the selected session's view (agent, shells, files).
class Home extends StatefulWidget {
  const Home({
    super.key,
    required this.link,
    required this.terms,
    required this.macs,
    required this.onSwitch,
    required this.onAddMac,
    required this.onLock,
    required this.onUnpair,
    required this.onRename,
    required this.onForget,
  });
  final Link link;
  final Terms terms;
  final List<MacPairing> macs;
  final void Function(MacPairing) onSwitch;
  final VoidCallback onAddMac, onLock, onUnpair;
  final Future<void> Function(MacPairing, String?) onRename;
  final Future<void> Function(MacPairing) onForget;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _files = <String, Files>{};
  final _views = <String, GlobalKey<SessionViewState>>{};
  String? _current;
  bool _recent = true; // the recent sessions page; the app opens on it
  double _font = 13;
  SharedPreferences? _prefs;
  late final _pins = Pins(_mac); // this device's, for this Mac
  late final _flows = SessionFlows(this, widget.terms,
      prefs: () => _prefs,
      select: _select,
      closeDrawer: () => _scaffold.currentState?.closeDrawer(),
      onResumed: _pins.resumed);

  Link get link => widget.link;
  Terms get terms => widget.terms;
  String get _mac => macKey(link);

  @override
  void initState() {
    super.initState();
    terms.onWake = _wake;
    terms.addListener(_openOnly);
    _openOnly(); // the list may be in already
    _taps = Notify.taps.listen(_tapped);
    if (_pendingTap != null) _tapped(_pendingTap!);
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _prefs = p;
        _font = p.getDouble('font') ?? 13;
        _current = p.getString('session:$_mac');
      });
    });
  }

  @override
  void didUpdateWidget(Home old) {
    super.didUpdateWidget(old);
    terms.onWake = _wake;
  }

  void _wake(TermTab t) {
    final s = terms.session(t.session);
    if (s != null) _flows.enter(s);
  }

  // The app opens on the recent page, but with just one session open it goes
  // straight into it, once the Mac's list has arrived.
  bool _opened = false;
  void _openOnly() {
    if (_opened || !terms.synced) return;
    _opened = true;
    terms.removeListener(_openOnly);
    final all = terms.sessions;
    if (_recent && all.length == 1 && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _recent && terms.sessions.length == 1) _select(terms.sessions.single.id);
      });
    }
  }

  // A tapped notification: its session, on its Mac. Another Mac's waits for
  // the Home that shows it.
  static String? _pendingTap;
  static bool _asked = false;
  StreamSubscription<String>? _taps;

  void _tapped(String payload) {
    final i = payload.indexOf('|');
    if (i < 0) return;
    final room = payload.substring(0, i), id = payload.substring(i + 1);
    if (room != link.pairing.room) {
      final m = widget.macs.where((m) => m.room == room).firstOrNull;
      if (m == null) return;
      _pendingTap = payload;
      widget.onSwitch(m);
      return;
    }
    _pendingTap = null;
    void go() {
      if (!mounted || terms.session(id) == null) return;
      terms.removeListener(go);
      _select(id);
    }
    if (terms.session(id) != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => go());
    } else {
      terms.addListener(go); // the Mac's list is not in yet
    }
  }

  @override
  void dispose() {
    _taps?.cancel();
    terms.removeListener(_openOnly);
    if (terms.onWake == _wake) terms.onWake = null;
    _pins.dispose();
    for (final f in _files.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _select(String id) {
    if (!_asked) {
      _asked = true;
      Notify.ask(); // to say when a session needs you
    }
    final to = terms.session(id);
    if (to != null) _flows.enter(to);
    setState(() {
      _current = id;
      _recent = false;
    });
    _prefs?.setString('session:$_mac', id);
  }

  Session? _currentOf(List<Session> all) =>
      all.where((s) => s.id == _current).firstOrNull ?? all.firstOrNull;

  Files _filesFor(Session s) => _files.putIfAbsent(s.id, () => Files(link, root: s.dir));

  /// Drops the files controllers of sessions that are gone.
  void _prune(List<Session> all) {
    if (terms.synced) WidgetsBinding.instance.addPostFrameCallback((_) => _pins.prune(terms.sessions));
    final ids = {for (final s in all) s.id};
    final gone = _files.keys.where((id) => !ids.contains(id)).toList();
    if (gone.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final id in gone) {
        if (ids.contains(id)) continue;
        _files.remove(id)?.dispose();
        _views.remove(id);
      }
    });
  }

  void _font_(double d) {
    setState(() => _font = (_font + d).clamp(9, 22));
    _prefs?.setDouble('font', _font);
  }

  Future<void> _newSession({String? dir}) async {
    _scaffold.currentState?.closeDrawer();
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => NewSessionPage(terms: terms, dir: dir)),
    );
    if (id != null && mounted) _select(id);
  }


  void _showRecent() {
    _scaffold.currentState?.closeDrawer();
    setState(() => _recent = true);
  }


  Future<void> _back() async {
    if (_recent && terms.sessions.isNotEmpty) {
      setState(() => _recent = false);
      return;
    }
    final s = _currentOf(terms.sessions);
    if (s != null && await _filesFor(s).back()) return;
    SystemNavigator.pop();
  }

  // ---- layout ----

  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.viewInsetsOf(context).bottom > 0;
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: ListenableBuilder(
        listenable: Listenable.merge([link, terms, _pins]),
        builder: (context, _) {
          final all = terms.sessions;
          _prune(all);
          final cur = _recent ? null : _currentOf(all);
          terms.viewing = cur?.id;
          return Scaffold(
            key: _scaffold,
            drawer: HomeDrawer(
              link: link,
              terms: terms,
              pins: _pins,
              macs: widget.macs,
              prefs: _prefs,
              mac: _mac,
              all: all,
              cur: cur,
              recent: _recent,
              closeDrawer: () => _scaffold.currentState?.closeDrawer(),
              onSwitch: widget.onSwitch,
              onManageMacs: _manageMacs,
              onNew: _newSession,
              onShowRecent: _showRecent,
              onResume: (dir, c) => _flows.resumeIn(dir, c),
              onRemoveDir: _forgetDir,
              onSelect: _select,
              onClose: _flows.closeSession,
              onLock: widget.onLock,
              onUnpair: _unpair,
            ),
            body: SafeArea(
              bottom: false,
              child: Column(children: [
                HomeTopBar(
                  link: link,
                  cur: cur,
                  recent: _recent,
                  statusBusy: _statusBusy,
                  font: _font,
                  onMenu: () => _scaffold.currentState?.openDrawer(),
                  onStatus: _statusSheet,
                  onFont: _font_,
                  onRestart: _flows.restart,
                  onClose: _flows.closeSession,
                ),
                ConnectionBanner(link: link, onUnpair: widget.onUnpair),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: kb ? 0 : bottomPad),
                    child: _body(all, cur, kb),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _recentPage(List<Session> all) => HomeRecent(
        link: link,
        prefs: _prefs,
        mac: _mac,
        all: all,
        pins: _pins,
        onNew: _newSession,
        onResume: _flows.resumeIn,
        onRemoveDir: _forgetDir,
      );

  Future<void> _forgetDir(String dir) async {
    await forgetRecentDir(_prefs, _mac, dir);
    if (mounted) setState(() {});
  }

  /// The view of the session on screen, where the status sheet types the lid command.
  SessionViewState? _currentView() {
    final s = _currentOf(terms.sessions);
    return s == null ? null : _views[s.id]?.currentState;
  }

  Widget _body(List<Session> all, Session? cur, bool kb) {
    if (!terms.synced) {
      return Center(
        child: Text(link.online ? 'Loading sessions…' : 'Waiting for your Mac…',
            style: const TextStyle(color: C.dim)),
      );
    }
    if (all.isEmpty) return _recentPage(all);
    final stack = IndexedStack(
      index: all.indexOf(cur ?? _currentOf(all)!),
      sizing: StackFit.expand,
      children: [
        for (final s in all)
          SessionView(
            key: _views.putIfAbsent(s.id, GlobalKey.new),
            terms: terms,
            session: s,
            files: _filesFor(s),
            fontSize: _font,
            keyboard: kb && s == cur,
            onRestart: () => _flows.restart(s),
            onConversation: (c) => _flows.openConversation(s, c),
          ),
      ],
    );
    if (cur != null) return stack;
    // The sessions stay alive underneath. expand: the offstage stack is 0×0,
    // and the page would be sized to it (blank).
    return Stack(fit: StackFit.expand, children: [Offstage(child: stack), _recentPage(all)]);
  }

  // ---- menus ----

  void _manageMacs() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MacsPage(
          link: link,
          terms: terms,
          macs: widget.macs,
          onSwitch: widget.onSwitch,
          onAdd: widget.onAddMac,
          onRename: widget.onRename,
          onForget: widget.onForget,
          localCore: MacPairing.hasLocal ? () => Link(MacPairing.local(), null)..start() : null,
        ),
      ),
    );
  }

  Future<void> _unpair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unpair ${link.host}?'),
        content: const Text(
            'This phone forgets this Mac and its key for it. Terminals on the Mac keep running. '
            'To connect again you need a new pairing code.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onUnpair();
  }

  // The sheet waits for the Mac's answer (usage can take seconds): one at a
  // time, and the icon spins until the sheet is up so it's clear the tap was
  // taken.
  bool _statusBusy = false;

  Future<void> _statusSheet() async {
    if (_statusBusy) return;
    setState(() => _statusBusy = true);
    try {
      await showMacStatus(context, link, _currentView, onShown: () {
        if (mounted) setState(() => _statusBusy = false);
      });
    } finally {
      if (mounted) setState(() => _statusBusy = false);
    }
  }
}
