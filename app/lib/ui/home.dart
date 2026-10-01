import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/claude.dart';
import '../model/terms.dart';
import '../net/link.dart';
import '../net/store.dart';
import 'agent_extras.dart';
import 'files_panel.dart';
import 'macs.dart';
import 'new_session.dart';
import 'session_view.dart';
import 'theme.dart';
import 'workspaces.dart';

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

  Link get link => widget.link;
  Terms get terms => widget.terms;
  String get _mac => macKey(link);

  @override
  void initState() {
    super.initState();
    terms.onWake = _wake;
    terms.addListener(_openOnly);
    _openOnly(); // the list may be in already
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
    if (s != null) _enter(s);
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

  @override
  void dispose() {
    terms.removeListener(_openOnly);
    if (terms.onWake == _wake) terms.onWake = null;
    for (final f in _files.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _select(String id) {
    final was = _recent ? null : _currentOf(terms.sessions);
    if (was != null && was.id != id) _leave(was);
    final to = terms.session(id);
    if (to != null) _enter(to);
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

  /// Runs the session's agent again with --continue: typed into its terminal
  /// when that still runs (the agent was quit), else in a new one.
  Future<void> _restart(Session s) async {
    final flags = _prefs?.getString('sessFlags.${s.id}') ?? '';
    final old = s.agent;
    final cmd = s.tool == 'cli' ? null : Terms.command(s.tool, continueFlags(flags));
    try {
      if (old != null && !old.exited) {
        if (cmd != null) terms.type(old, '$cmd\r');
        return;
      }
      await terms.open(session: s.id, dir: s.dir, kind: s.tool, cmd: cmd, sizeLike: old);
      if (old != null) terms.close(old);
    } on RpcError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  /// Shows a conversation picked from the folder's history: the session that
  /// already has it open, or a new session resuming it.
  Future<void> _openConversation(Session from, Conversation c) =>
      _resumeIn(from.dir, c, flagsOf: from.tool == c.tool ? from.id : null);

  /// Resumes a conversation in [dir] with the agent that had it, with the
  /// flags of session [flagsOf] or else of the folder's newest session of
  /// that agent.
  Future<void> _resumeIn(String dir, Conversation c, {String? flagsOf}) async {
    _scaffold.currentState?.closeDrawer();
    final here = terms.sessions.where((s) => c.term != 0 && s.agent?.id == c.term).firstOrNull;
    if (here != null) {
      _select(here.id);
      return;
    }
    final name = tools[c.tool] ?? c.tool;
    final canMove = c.tool == 'claude'; // chat.stop knows how to quit Claude only
    if (c.running) {
      final how = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Open on the Mac'),
          content: Text('$name has this conversation open on the Mac, in a terminal or in an editor.\n\n'
              '${canMove ? 'Move here quits that $name (it saves first) and carries on here with everything so far.\n\n' : ''}'
              'Open here too keeps both, but neither sees the other\'s new messages.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            if (canMove) TextButton(onPressed: () => Navigator.pop(ctx, 'both'), child: const Text('Open here too')),
            if (canMove)
              FilledButton(onPressed: () => Navigator.pop(ctx, 'move'), child: const Text('Move here'))
            else
              FilledButton(onPressed: () => Navigator.pop(ctx, 'both'), child: const Text('Open here too')),
          ],
        ),
      );
      if (how == null) return;
      if (how == 'move') {
        try {
          await link.call('chat.stop', {'session': c.id}, const Duration(seconds: 15));
        } on RpcError catch (e) {
          if (mounted) toast(context, e.message, error: true);
          return;
        }
      }
    }
    flagsOf ??= terms.sessions.where((s) => s.dir == dir && s.tool == c.tool).lastOrNull?.id;
    final flags = resumeFlags(_prefs?.getString('sessFlags.$flagsOf') ?? '', c.id);
    try {
      final id = await terms.start(dir, flags, tool: c.tool);
      await _prefs?.setString('sessFlags.$id', flags);
      if (mounted) _select(id);
    } on RpcError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  Future<void> _closeSession(Session s) async {
    final n = s.shells.where((t) => !t.exited).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Close ${s.name}?'),
        content: Text('This ends ${s.toolName}${n == 0 ? '' : ' and $n shell${n == 1 ? '' : 's'}'} on the Mac.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final c in await terms.closeSession(s.id)) {
      _seen.readNow(c); // seen here: gray in the lists, not unread
    }
    _prefs?.remove('sessFlags.${s.id}');
  }

  void _showRecent() {
    _scaffold.currentState?.closeDrawer();
    final was = _recent ? null : _currentOf(terms.sessions);
    if (was != null) _leave(was);
    setState(() => _recent = true);
  }

  SeenConversations get _seen => SeenConversations(_prefs, _mac);

  /// Leaving a session: an idle Claude quits, so the conversation is free for
  /// the laptop or another phone. Its last answer was seen here.
  Future<void> _leave(Session s) async {
    try {
      final conv = await terms.park(s);
      if (conv != null) _seen.readNow(conv);
    } on RpcError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  /// Coming back: a parked Claude starts again, unless the conversation was
  /// picked up elsewhere meanwhile; then it's the user's call.
  Future<void> _enter(Session s) async {
    if (s.agent?.parked != true || !_waking.add(s.id)) return;
    try {
      await _unpark(s);
    } finally {
      _waking.remove(s.id);
    }
  }

  final _waking = <String>{};

  Future<void> _unpark(Session s) async {
    try {
      await terms.unpark(s);
    } on RpcError catch (e) {
      if (e.code != 'busy' || !mounted) {
        if (mounted) toast(context, e.message, error: true);
        return;
      }
      final take = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Open on the Mac'),
          content: const Text('This conversation was picked up on the Mac (a terminal or an editor) while you were away.\n\n'
              'Move here quits that Claude (it saves first) and carries on here.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Leave it there')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Move here')),
          ],
        ),
      );
      if (take != true) return;
      try {
        await terms.unpark(s, take: true);
      } on RpcError catch (e) {
        if (mounted) toast(context, e.message, error: true);
      }
    }
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
        listenable: Listenable.merge([link, terms]),
        builder: (context, _) {
          final all = terms.sessions;
          _prune(all);
          final cur = _recent ? null : _currentOf(all);
          terms.viewing = cur?.id;
          return Scaffold(
            key: _scaffold,
            drawer: _drawer(all, cur),
            body: SafeArea(
              bottom: false,
              child: Column(children: [
                _topBar(cur),
                _banner(),
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

  Widget _body(List<Session> all, Session? cur, bool kb) {
    if (!terms.synced) {
      return Center(
        child: Text(link.online ? 'Loading sessions…' : 'Waiting for your Mac…',
            style: const TextStyle(color: C.dim)),
      );
    }
    if (all.isEmpty) return _empty(all);
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
            onRestart: () => _restart(s),
            onConversation: (c) => _openConversation(s, c),
          ),
      ],
    );
    if (cur != null) return stack;
    // The sessions stay alive underneath.
    return Stack(children: [Offstage(child: stack), Positioned.fill(child: _empty(all))]);
  }

  /// The recent sessions page: new session, the Mac's newest conversations
  /// from every folder, and recent folders.
  Widget _empty(List<Session> all) {
    final recent = _prefs?.getStringList('recentDirs:$_mac') ?? [];
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (all.isEmpty) ...[
              const SizedBox(height: 12),
              const Icon(Icons.auto_awesome_rounded, size: 40, color: C.accent),
              const SizedBox(height: 14),
              Text('No sessions open on ${link.host}',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text('Pick up a recent one, or start Claude Code, Copilot or a terminal in a folder.',
                  textAlign: TextAlign.center, style: TextStyle(color: C.dim)),
              const SizedBox(height: 22),
            ],
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: link.online ? () => _newSession() : null,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New session'),
            ),
            const SizedBox(height: 18),
            RecentList(
              key: ValueKey(_prefs == null),
              link: link,
              prefs: _prefs,
              mac: _mac,
              sessions: all,
              onResume: _resumeIn,
            ),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 22),
              const Text('Recent folders', style: TextStyle(color: C.dim, fontSize: 13)),
              const SizedBox(height: 6),
              for (final d in recent)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_rounded, color: C.amber),
                  title: Text(baseName(d)),
                  subtitle: Text(tildePath(d, link.home), overflow: TextOverflow.ellipsis),
                  onTap: link.online ? () => _newSession(dir: d) : null,
                ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _topBar(Session? cur) {
    final (color, label) = switch (link.state) {
      LinkState.online => (C.green, 'connected'),
      LinkState.connecting => (C.amber, 'connecting…'),
      LinkState.offline => (C.red, 'offline'),
      LinkState.refused => (C.red, 'refused'),
    };
    return SizedBox(
      height: 52,
      child: Row(children: [
        IconButton(
          tooltip: 'Sessions',
          icon: const Icon(Icons.menu_rounded),
          onPressed: () => _scaffold.currentState?.openDrawer(),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: color.withValues(alpha: .6), blurRadius: 8)],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cur?.name ?? link.host,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text(
              cur == null ? (_recent && link.online ? 'Recent sessions' : label) : '${link.host} · ${tildePath(cur.dir, link.home)}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: C.dim, fontSize: 11.5),
            ),
          ]),
        ),
        IconButton(
          tooltip: 'Mac status',
          icon: _statusBusy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.laptop_mac_rounded, size: 21),
          onPressed: link.online ? _statusSheet : null,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (v) => switch (v) {
            'bigger' => _font_(1),
            'smaller' => _font_(-1),
            'restart' => cur == null ? null : _restart(cur),
            'close' => cur == null ? null : _closeSession(cur),
            _ => null,
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: Row(children: [
                const Text('Text size', style: TextStyle(color: C.text)),
                const Spacer(),
                Text('${_font.round()}', style: const TextStyle(color: C.dim)),
              ]),
            ),
            const PopupMenuItem(value: 'bigger', child: Text('Larger text  A+')),
            const PopupMenuItem(value: 'smaller', child: Text('Smaller text  A−')),
            if (cur != null) ...[
              const PopupMenuDivider(),
              if (cur.tool != 'cli')
                PopupMenuItem(value: 'restart', child: Text('Run ${cur.tool} --continue')),
              PopupMenuItem(value: 'close', child: Text('Close ${cur.name}…')),
            ],
          ],
        ),
      ]),
    );
  }

  static IconData toolIcon(String tool) => switch (tool) {
        'copilot' => Icons.flight_rounded,
        'cli' => Icons.terminal_rounded,
        _ => Icons.auto_awesome_rounded,
      };

  Widget _drawer(List<Session> all, Session? cur) {
    return Drawer(
      backgroundColor: C.panel,
      child: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
              _section('Macs'),
              for (final m in widget.macs)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.laptop_mac_rounded, color: m.room == link.pairing.room ? C.accent : C.dim),
                  title: Text(m.room == link.pairing.room ? link.host : m.name,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  trailing: m.room == link.pairing.room ? const Icon(Icons.check_rounded, color: C.accent) : null,
                  onTap: () {
                    _scaffold.currentState?.closeDrawer();
                    widget.onSwitch(m);
                  },
                ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.tune_rounded, color: C.dim),
                title: const Text('Manage Macs'),
                subtitle: const Text('Pair, rename, remove, shell', style: TextStyle(fontSize: 12)),
                onTap: () {
                  _scaffold.currentState?.closeDrawer();
                  _manageMacs();
                },
              ),
              const Divider(height: 20),
              Row(children: [
                Expanded(child: _section('Folders on ${link.host}')),
                IconButton(
                  tooltip: 'New session',
                  icon: const Icon(Icons.add_rounded),
                  onPressed: link.online ? () => _newSession() : null,
                ),
              ]),
              ListTile(
                dense: true,
                selected: _recent,
                leading: const Icon(Icons.history_rounded),
                title: const Text('Recent sessions', style: TextStyle(fontSize: 14.5)),
                onTap: _showRecent,
              ),
              if (all.isEmpty && terms.synced)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text('None yet', style: TextStyle(color: C.dim)),
                ),
              WorkspaceList(
                link: link,
                prefs: _prefs,
                mac: _mac,
                sessions: all,
                dirs: [
                  ...{
                    for (final s in all) s.dir,
                    ...?_prefs?.getStringList('recentDirs:$_mac'),
                  },
                ],
                tile: (s) => _sessionTile(s, s == cur),
                onNew: (dir) => _newSession(dir: dir),
                onResume: (dir, c) => _resumeIn(dir, c),
              ),
            ]),
          ),
          const Divider(height: 1),
          Row(children: [
            Expanded(
              child: TextButton.icon(
                onPressed: widget.onLock,
                icon: const Icon(Icons.lock_rounded, size: 18),
                label: const Text('Lock'),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: C.red),
                onPressed: _unpair,
                icon: const Icon(Icons.link_off_rounded, size: 18),
                label: const Text('Unpair'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
        child: Text(t.toUpperCase(),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: C.dim, fontSize: 11.5, letterSpacing: .8, fontWeight: FontWeight.w600)),
      );

  Widget _sessionTile(Session s, bool sel) {
    final live = s.agent != null && !s.agent!.exited;
    final unread = !sel && (s.agent?.unread ?? false);
    final flags = _prefs?.getString('sessFlags.${s.id}') ?? '';
    final shells = s.shells.where((t) => !t.exited).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 2, 8, 2),
      child: Material(
        color: sel ? C.accent.withValues(alpha: .14) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            _select(s.id);
            _scaffold.currentState?.closeDrawer();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
            child: Row(children: [
              Stack(clipBehavior: Clip.none, children: [
                Icon(toolIcon(s.tool), size: 22, color: sel ? C.accent : C.text),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: StatusDot(
                    unread
                        ? StatusDot.unread
                        : live
                            ? StatusDot.active
                            : StatusDot.idle,
                    size: 9,
                    border: C.panel,
                  ),
                ),
              ]),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.agent?.title.isNotEmpty == true && s.agent!.title != s.tool ? s.agent!.title : s.toolName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(
                    [
                      live ? 'open on the phone' : 'ended',
                      if (flags.isNotEmpty) flags,
                      if (shells > 0) '$shells shell${shells == 1 ? '' : 's'}',
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: C.dim, fontSize: 12),
                  ),
                ]),
              ),
              IconButton(
                tooltip: 'Close session',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 18, color: C.dim),
                onPressed: () => _closeSession(s),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _banner() {
    final s = link.state;
    if (s == LinkState.online) return const SizedBox.shrink();
    if (s == LinkState.connecting && link.error == null) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    final refused = s == LinkState.refused;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: (refused ? C.red : C.amber).withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(refused ? Icons.block_rounded : Icons.cloud_off_rounded,
            size: 18, color: refused ? C.red : C.amber),
        const SizedBox(width: 10),
        Expanded(
          child: Text(link.error ?? 'Not connected',
              style: const TextStyle(fontSize: 13), maxLines: 3, overflow: TextOverflow.ellipsis),
        ),
        if (refused)
          TextButton(onPressed: widget.onUnpair, child: const Text('Pair again'))
        else
          TextButton(
            onPressed: s == LinkState.connecting ? null : link.reconnectNow,
            child: Text(s == LinkState.connecting ? 'Retrying…' : 'Retry'),
          ),
      ]),
    );
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
  // time, and the icon spins meanwhile so it's clear the tap was taken.
  bool _statusBusy = false;

  Future<void> _statusSheet() async {
    if (_statusBusy) return;
    setState(() => _statusBusy = true);
    try {
      await _showStatus();
    } finally {
      if (mounted) setState(() => _statusBusy = false);
    }
  }

  Future<void> _showStatus() async {
    Map? s;
    ClaudeUsage? usage;
    final u = link
        .call('usage', null, const Duration(seconds: 25)) // the Mac asks Claude Code and GitHub
        .then((r) => ClaudeUsage.from(r as Map))
        .then<ClaudeUsage?>((v) => v, onError: (_) => null); // an older agent has no usage
    try {
      s = await link.call('sys.status', null, const Duration(seconds: 8)) as Map;
      usage = await u;
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
      return;
    }
    if (!mounted) return;
    final lid = s['lidAwake'] == true;
    Future<List<AccountTokens>> reset(AccountTokens a) async {
      final r = await link.call('tokens.reset', {'tool': a.tool, 'account': a.account}, const Duration(seconds: 30));
      return [for (final t in r as List) AccountTokens.from(t as Map)];
    }

    // Each account's tokens sit under its plan; accounts not signed in, below.
    bool claudes(AccountTokens a) => a.tool == 'claude' && a.account == usage?.email;
    bool copilots(AccountTokens a) => a.tool == 'copilot' && a.account == usage?.copilot?.login;
    bool others(AccountTokens a) => !claudes(a) && !copilots(a);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      // Short of the top, so dragging it down never pulls the notifications.
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 8),
            child: Row(children: [
              Expanded(
                child: Text(s!['host'] ?? link.host,
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              ),
              IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(ctx)),
            ]),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (usage != null) ...[
              UsageCard(usage),
              TokensCard(usage.tokens, keep: claudes, onReset: reset),
              const Divider(height: 28),
              if (usage.copilot != null) ...[
                CopilotCard(usage.copilot!),
                TokensCard(usage.tokens, keep: copilots, onReset: reset),
                const Divider(height: 28),
              ],
              if (usage.tokens.any(others)) ...[
                TokensCard(usage.tokens, keep: others, title: 'Other accounts', onReset: reset),
                const Text('Copilot\'s tokens count once a Copilot session ends.',
                    style: TextStyle(fontSize: 11.5, color: C.dim)),
                const Divider(height: 28),
              ],
            ],
            const Text('This Mac', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            _row(Icons.battery_charging_full_rounded, 'Battery', s['battery'] ?? '—'),
            _row(Icons.power_rounded, 'Power', s['power'] ?? '—'),
            _row(Icons.coffee_rounded, 'Kept awake while idle', s['keepAwake'] == true ? 'yes' : 'no'),
            const Divider(height: 28),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: lid,
              title: const Text('Stay awake with the lid closed'),
              subtitle: Text(
                lid
                    ? 'On. Sleep is disabled until you switch this off.'
                    : 'Runs “sudo pmset -a disablesleep 1” in a new terminal; type your Mac password there.',
                style: const TextStyle(fontSize: 12.5, color: C.dim),
              ),
              onChanged: (v) {
                Navigator.pop(ctx);
                final s = _currentOf(terms.sessions);
                final view = s == null ? null : _views[s.id]?.currentState;
                if (view == null) {
                  toast(context, 'Start a session first', error: true);
                  return;
                }
                view.runInShell('sudo pmset -a disablesleep ${v ? 1 : 0}\r', newTab: true);
                toast(context, 'Enter your Mac password in the shell');
              },
            ),
            if (lid)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'A closed MacBook in a bag can get hot. Switch this off when you are done.',
                  style: TextStyle(color: C.amber, fontSize: 12.5),
                ),
              ),
          ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _row(IconData i, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Icon(i, size: 18, color: C.dim),
          const SizedBox(width: 12),
          Text(k, style: const TextStyle(color: C.dim)),
          const Spacer(),
          Flexible(child: Text(v, textAlign: TextAlign.end, overflow: TextOverflow.ellipsis)),
        ]),
      );
}
