import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/terms.dart';
import '../net/link.dart';
import 'files_panel.dart';
import 'shells.dart';
import 'theme.dart';

const _flagChips = {
  'claude': ['--continue', '--resume', '--dangerously-skip-permissions', '--model opus', '--model sonnet'],
  'copilot': ['--continue', '--resume', '--allow-all-tools', '--allow-all-paths'],
  'cli': <String>[],
};

/// Picks a folder on the Mac, the agent (Claude Code, Copilot or a plain
/// terminal) and its flags, then starts the session. Pops with its id.
class NewSessionPage extends StatefulWidget {
  const NewSessionPage({super.key, required this.terms, this.dir});
  final Terms terms;
  final String? dir; // start browsing here
  @override
  State<NewSessionPage> createState() => _NewSessionPageState();
}

class _NewSessionPageState extends State<NewSessionPage> {
  final _flags = TextEditingController();
  SharedPreferences? _prefs;
  List<String> _recent = [];
  String? _cwd;
  List<Entry> _dirs = [];
  String? _error;
  bool _loading = false, _starting = false, _flagsTouched = false, _toolTouched = false;
  String _tool = 'claude';
  String? _shell; // null: the Mac's default
  ShellInfo? _shells;

  Link get link => widget.terms.link;
  String get _mac => macKey(link);
  String _flagsKey(String dir) => 'flags:$_mac:$_tool:$dir';
  String _toolKey(String dir) => 'tool:$_mac:$dir';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      _prefs = p;
      _recent = p.getStringList('recentDirs:$_mac') ?? [];
      _tool = p.getString('tool') ?? 'claude';
      final start = widget.dir ?? (_recent.isEmpty ? link.home : parentOf(_recent.first));
      _go(start);
    });
    widget.terms.shellInfo().then((i) {
      if (mounted) setState(() => _shells = i);
    }, onError: (_) {});
  }

  Future<void> _pickShell() async {
    final s = await pickShell(context, widget.terms, title: 'Run in', selected: _shell);
    // The page may have opened before the Mac answered: the sheet asked again.
    final i = await widget.terms.shellInfo().catchError((_) => _shells);
    if (!mounted) return;
    setState(() {
      _shells = i ?? _shells;
      if (s != null) _shell = s == _shells?.current ? null : s;
    });
  }

  @override
  void dispose() {
    _flags.dispose();
    super.dispose();
  }

  Future<void> _go(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await link.call('fs.list', {'path': path}) as Map;
      final entries = (r['entries'] as List? ?? []).map((m) => Entry(m as Map)).where((e) => e.dir).toList()
        ..sort((a, b) {
          final ah = a.name.startsWith('.'), bh = b.name.startsWith('.');
          if (ah != bh) return ah ? 1 : -1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      if (!mounted) return;
      setState(() {
        _cwd = r['path'] as String;
        _dirs = entries;
        // A tool picked on this page stays while browsing folders.
        if (!_toolTouched) _tool = _prefs?.getString(_toolKey(_cwd!)) ?? _prefs?.getString('tool') ?? _tool;
        if (!_flagsTouched) _flags.text = _prefs?.getString(_flagsKey(_cwd!)) ?? '';
      });
    } on RpcError catch (e) {
      if (!mounted) return;
      if (_cwd == null && path != link.home) return _go(link.home);
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggleFlag(String f) {
    var toks = _flags.text.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    final had = _hasFlag(f);
    // Remove the flag (and, for flags with a value, its value) plus anything
    // it can't be combined with.
    List<String> drop(List<String> t, String name, {bool value = false}) {
      final out = <String>[];
      for (var i = 0; i < t.length; i++) {
        if (t[i] == name) {
          if (value && i + 1 < t.length && !t[i + 1].startsWith('-')) i++;
          continue;
        }
        out.add(t[i]);
      }
      return out;
    }

    final name = f.split(' ').first;
    toks = drop(toks, name, value: name == '--model' || name == '--resume');
    if (name == '--continue') toks = drop(toks, '--resume', value: true);
    if (name == '--resume') toks = drop(toks, '--continue');
    if (!had) toks.addAll(f.split(' '));
    _flags.text = toks.join(' ');
    _flagsTouched = true;
    setState(() {});
  }

  bool _hasFlag(String f) => ' ${_flags.text.trim()} '.contains(' $f ');

  Future<void> _start() async {
    final dir = _cwd;
    if (dir == null || _starting) return;
    setState(() => _starting = true);
    try {
      final flags = _flags.text.trim();
      final id = await widget.terms.start(dir, flags, tool: _tool, shell: _shell);
      final p = _prefs;
      if (p != null) {
        _recent = [dir, ..._recent.where((d) => d != dir)].take(8).toList();
        await p.setStringList('recentDirs:$_mac', _recent);
        await p.setString(_flagsKey(dir), flags);
        await p.setString('sessFlags.$id', flags);
        await p.setString('tool', _tool);
        await p.setString(_toolKey(dir), _tool);
      }
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.pop(context, id);
    } on RpcError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cwd = _cwd;
    return Scaffold(
      appBar: AppBar(title: const Text('New session')),
      body: Column(children: [
        if (_recent.isNotEmpty)
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final d in _recent)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: const Icon(Icons.history_rounded, size: 16),
                      label: Text(baseName(d)),
                      onPressed: () => _go(d),
                    ),
                  ),
              ],
            ),
          ),
        Container(
          color: C.panel,
          padding: const EdgeInsets.only(left: 4, right: 12),
          height: 44,
          child: Row(children: [
            IconButton(
              tooltip: 'Up',
              icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              onPressed: cwd == null || cwd == '/' ? null : () => _go(parentOf(cwd)),
            ),
            Expanded(
              child: Text(
                cwd == null ? '' : tildePath(cwd, link.home),
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.rtl, // keep the end of a long path visible
                style: const TextStyle(fontFamily: mono, fontSize: 13),
              ),
            ),
            if (_loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
        ),
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: C.red)))
              : ListView.builder(
                  itemCount: _dirs.length,
                  itemBuilder: (context, i) {
                    final e = _dirs[i];
                    final hidden = e.name.startsWith('.');
                    return ListTile(
                      dense: true,
                      leading: Icon(Icons.folder_rounded, color: hidden ? C.dim : C.amber, size: 22),
                      title: Text(e.name, style: TextStyle(fontSize: 15, color: hidden ? C.dim : C.text)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: C.dim),
                      onTap: () => _go(joinPath(cwd!, e.name)),
                    );
                  },
                ),
        ),
        _startPanel(cwd),
      ]),
    );
  }

  Widget _startPanel(String? cwd) {
    return Container(
      decoration: const BoxDecoration(color: C.panel, border: Border(top: BorderSide(color: C.line))),
      padding: EdgeInsets.fromLTRB(14, 10, 14, 10 + MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'claude', label: Text('Claude'), icon: Icon(Icons.auto_awesome_rounded, size: 17)),
            ButtonSegment(value: 'copilot', label: Text('Copilot'), icon: Icon(Icons.flight_rounded, size: 17)),
            ButtonSegment(value: 'cli', label: Text('Terminal'), icon: Icon(Icons.terminal_rounded, size: 17)),
          ],
          selected: {_tool},
          onSelectionChanged: (v) => setState(() {
            _tool = v.first;
            _toolTouched = true;
            _flagsTouched = false;
            final cwd = _cwd;
            // Kept even if the start fails, so the choice sticks.
            _prefs?.setString('tool', _tool);
            _flags.text = cwd == null ? '' : _prefs?.getString(_flagsKey(cwd)) ?? '';
          }),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _flags,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => _flagsTouched = true),
          style: const TextStyle(fontFamily: mono, fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            prefixText: _tool == 'cli' ? null : '$_tool ',
            hintText: _tool == 'cli' ? 'command to run first (optional)' : 'flags (optional)',
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 2, children: [
          for (final f in _flagChips[_tool]!)
            FilterChip(
              label: Text(f, style: const TextStyle(fontFamily: mono, fontSize: 12)),
              selected: _hasFlag(f),
              visualDensity: VisualDensity.compact,
              onSelected: (_) => _toggleFlag(f),
            ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: OutlinedButton.icon(
              onPressed: _pickShell,
              icon: const Icon(Icons.expand_more_rounded, size: 18),
              label: Text(shellName(_shell ?? _shells?.current ?? 'shell'), style: const TextStyle(fontFamily: mono)),
            ),
          ),
          Expanded(
            child: FilledButton.icon(
              onPressed: cwd == null || _starting || !link.online ? null : _start,
              icon: _starting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(cwd == null ? 'Start' : 'Start ${tools[_tool]} in ${baseName(cwd)}',
                  overflow: TextOverflow.ellipsis),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// Prefs keys that differ per paired Mac.
String macKey(Link link) => link.pairing.room.substring(0, 12);

String baseName(String p) {
  final parts = p.split('/').where((s) => s.isNotEmpty);
  return parts.isEmpty ? '/' : parts.last;
}

String tildePath(String p, String home) =>
    home.length > 1 && p.startsWith(home) ? '~${p.substring(home.length)}' : p;

/// The saved flags resuming one conversation, for opening it in a new session.
String resumeFlags(String flags, String id) =>
    continueFlags(flags).replaceFirst('--continue', '--resume $id');

/// The saved flags with --continue in place of any resume choice, for
/// restarting a session's Claude.
String continueFlags(String flags) {
  final t = flags.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  final out = <String>['--continue'];
  for (var i = 0; i < t.length; i++) {
    if (t[i] == '--continue' || t[i] == '-c') continue;
    if (t[i] == '--resume' || t[i] == '-r') {
      if (i + 1 < t.length && !t[i + 1].startsWith('-')) i++;
      continue;
    }
    out.add(t[i]);
  }
  return out.join(' ');
}
