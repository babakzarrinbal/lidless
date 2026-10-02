import 'package:flutter/material.dart';

import '../model/terms.dart';
import '../net/link.dart';
import '../net/store.dart';
import 'devices.dart';
import 'shells.dart';
import 'theme.dart';

/// The Devices page: this device on top (on a Mac, with the devices paired
/// with it), then every other Mac this app reaches: switch, rename, remove,
/// add one, and the default shell of the one connected.
class MacsPage extends StatefulWidget {
  const MacsPage({
    super.key,
    required this.link,
    required this.terms,
    required this.macs,
    required this.onSwitch,
    required this.onAdd,
    required this.onRename,
    required this.onForget,
    this.localCore,
  });
  final Link link;
  final Terms terms;
  final List<MacPairing> macs;
  final void Function(MacPairing) onSwitch;
  final VoidCallback onAdd;
  final Future<void> Function(MacPairing, String?) onRename;
  final Future<void> Function(MacPairing) onForget;

  /// Opens a link to this Mac's own core when the one on screen is another
  /// Mac's (null: not a Mac, or a test).
  final Link Function()? localCore;

  @override
  State<MacsPage> createState() => _MacsPageState();
}

class _MacsPageState extends State<MacsPage> {
  late List<MacPairing> _macs = [
    for (final m in widget.macs) m.room == link.pairing.room ? link.pairing : m,
  ];
  Link? _local, _ownLocal; // this Mac's core; _ownLocal if this page opened it
  ShellInfo? _shells;
  bool _shellsOld = false, _shellsBusy = true;

  Link get link => widget.link;
  bool _current(MacPairing m) => m.room == link.pairing.room;

  @override
  void initState() {
    super.initState();
    _local = link.pairing.isLocal ? link : (_ownLocal = widget.localCore?.call());
    _loadShells();
  }

  @override
  void dispose() {
    _ownLocal?.dispose();
    super.dispose();
  }

  Future<void> _loadShells() async {
    setState(() => _shellsBusy = true);
    try {
      final i = await widget.terms.shellInfo();
      if (!mounted) return;
      setState(() {
        _shells = i;
        _shellsOld = i == null;
      });
    } catch (_) {
      // offline: the tile offers a retry
    } finally {
      if (mounted) setState(() => _shellsBusy = false);
    }
  }

  Future<void> _setShell() async {
    final s = await pickShell(context, widget.terms, title: 'Default shell on ${link.host}', selected: _shells?.current);
    if (s == null || !mounted) return;
    try {
      final i = await widget.terms.setDefaultShell(s);
      if (mounted) setState(() => _shells = i);
    } on RpcError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  Future<void> _rename(MacPairing m) async {
    final nick = await showDialog<String>(context: context, builder: (_) => _RenameDialog(m));
    if (nick == null || !mounted) return;
    final n = nick.trim();
    final v = n.isEmpty || n == m.host ? null : n;
    await widget.onRename(m, v);
    if (mounted) setState(() => _macs = [for (final x in _macs) x.room == m.room ? x.withNick(v) : x]);
  }

  Future<void> _remove(MacPairing m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${m.name}?'),
        content: const Text('This phone forgets this Mac and its key for it. Terminals on the Mac keep running. '
            'To connect again you need a new pairing code.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_current(m)) {
      // The screen behind is about to be replaced: leave first.
      Navigator.pop(context);
      widget.onForget(m);
      return;
    }
    await widget.onForget(m);
    if (mounted) setState(() => _macs = _macs.where((x) => x.room != m.room).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        for (final m in _macs.where((m) => m.isLocal)) ..._tile(m),
        if (!_macs.any((m) => m.isLocal)) _phoneTile(),
        if (_local != null) PairedDevicesSection(link: _local!),
        const Divider(height: 24),
        if (_macs.any((m) => !m.isLocal)) _header('Other devices'),
        for (final m in _macs.where((m) => !m.isLocal)) ..._tile(m),
        ListTile(
          leading: const Icon(Icons.add_link_rounded, color: C.accent),
          title: const Text('Add a device'),
          subtitle: const Text('Scan or paste its pairing code'),
          onTap: () {
            Navigator.pop(context);
            widget.onAdd();
          },
        ),
      ]),
    );
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
        child: Text(t.toUpperCase(),
            style: const TextStyle(color: C.dim, fontSize: 11.5, letterSpacing: .8, fontWeight: FontWeight.w600)),
      );

  /// A phone has no core of its own yet: just its name, as its Macs know it.
  Widget _phoneTile() => ListTile(
        leading: const Icon(Icons.smartphone_rounded, color: C.accent),
        title: const Text('This device', style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(link.deviceName, style: const TextStyle(fontSize: 12, color: C.dim)),
      );

  List<Widget> _tile(MacPairing m) {
    final cur = _current(m);
    final real = cur ? link.hostname : m.host;
    return [
      ListTile(
        leading: Icon(Icons.laptop_mac_rounded, color: cur ? C.accent : C.dim),
        title: Text(m.isLocal ? 'This device' : m.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
            [
              if (m.isLocal) real,
              if (!m.isLocal && m.nick != null) real,
              if (cur) link.online ? 'connected' : 'this one, offline',
            ].join(' · '),
            style: m.isLocal ? const TextStyle(fontSize: 12, color: C.dim) : null),
        onTap: cur
            ? null
            : () {
                Navigator.pop(context);
                widget.onSwitch(m);
              },
        trailing: m.isLocal && cur ? null : PopupMenuButton<String>(
          onSelected: (v) => switch (v) {
            'open' => () {
                Navigator.pop(context);
                widget.onSwitch(m);
              }(),
            'rename' => _rename(m),
            _ => _remove(m),
          },
          itemBuilder: (_) => [
            if (!cur) const PopupMenuItem(value: 'open', child: Text('Open')),
            // This Mac's own core is always here, under its own name.
            if (!m.isLocal) const PopupMenuItem(value: 'rename', child: Text('Rename')),
            if (!m.isLocal) const PopupMenuItem(value: 'remove', child: Text('Remove', style: TextStyle(color: C.red))),
          ],
        ),
      ),
      if (cur) _shellTile(),
    ];
  }

  Widget _shellTile() {
    final i = _shells;
    final String sub;
    VoidCallback? tap;
    if (_shellsBusy) {
      sub = 'Asking the Mac…';
    } else if (_shellsOld) {
      sub = 'Update bz-uniai on the Mac to choose (brew upgrade uniai, then brew services restart uniai)';
    } else if (i == null) {
      sub = 'Couldn\'t ask the Mac · tap to retry';
      tap = _loadShells;
    } else {
      sub = '${shellName(i.current)} · ${i.current}${i.def.isEmpty ? ' (login shell)' : ''}';
      tap = _setShell;
    }
    return Padding(
      padding: const EdgeInsets.only(left: 40),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.terminal_rounded, size: 20),
        title: const Text('Default shell for new terminals'),
        subtitle: Text(sub),
        trailing: tap == _setShell ? const Icon(Icons.chevron_right_rounded, color: C.dim) : null,
        onTap: tap,
      ),
    );
  }
}

// Owns its controller: the dialog still builds while it animates out.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog(this.mac);
  final MacPairing mac;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _c = TextEditingController(text: widget.mac.name);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.mac.host;
    return AlertDialog(
      title: const Text('Rename Mac'),
      content: TextField(
        controller: _c,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(hintText: host, helperText: 'Empty: use the Mac\'s own name ($host)'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: const Text('Save')),
      ],
    );
  }
}
