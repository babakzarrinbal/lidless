// The devices paired with this Mac, managed from this Mac's own app: the
// list with who is online, rename, remove, and a pairing code (QR + text)
// for a new one. Model: model/devices.dart. Core: cmd/uniai/devices.go.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../model/devices.dart';
import '../net/link.dart';
import 'theme.dart';

/// The section under "This device" on a Mac.
class PairedDevicesSection extends StatefulWidget {
  const PairedDevicesSection({super.key, required this.link});
  final Link link; // to this Mac's own core

  @override
  State<PairedDevicesSection> createState() => _PairedDevicesSectionState();
}

class _PairedDevicesSectionState extends State<PairedDevicesSection> {
  late final _d = Devices(widget.link);
  List<PairedDevice>? _list;
  String? _error;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _d.changes.listen((_) => _load());
    widget.link.addListener(_onLink);
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.link.removeListener(_onLink);
    super.dispose();
  }

  // The core may still be starting: ask again once it is up.
  void _onLink() {
    if (widget.link.online && _list == null) _load();
  }

  Future<void> _load() async {
    if (!widget.link.online) return;
    try {
      final l = await _d.list();
      if (mounted) {
        setState(() {
          _list = l;
          _error = null;
        });
      }
    } on RpcError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.code == 'unknown' ? 'Update the core on this Mac to manage its devices.' : e.message);
    }
  }

  Future<void> _rename(PairedDevice d) async {
    final name = await showDialog<String>(context: context, builder: (_) => _NameDialog(d.name));
    if (name == null || name.trim().isEmpty || !mounted) return;
    await _do(() => _d.rename(d.pub, name.trim()));
  }

  Future<void> _remove(PairedDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: const Text('It can no longer reach this Mac. To connect it again, pair it with a new code.'),
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
    if (ok == true && mounted) await _do(() => _d.remove(d.pub));
  }

  Future<void> _do(Future<List<PairedDevice>> Function() f) async {
    try {
      final l = await f();
      if (mounted) setState(() => _list = l);
    } on RpcError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  Future<void> _pair() async {
    final PairCode code;
    try {
      code = await _d.pair();
    } on RpcError catch (e) {
      if (mounted) toast(context, e.message, error: true);
      return;
    }
    if (!mounted) return;
    final added = await showDialog<String>(
      context: context,
      builder: (_) => PairCodeDialog(code: code, devices: _d, known: {for (final d in _list ?? const []) d.pub}),
    );
    if (added != null && mounted) toast(context, 'Paired with $added');
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _Header('Paired with this Mac'),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(_error!, style: const TextStyle(color: C.dim, fontSize: 13)),
        )
      else if (l == null)
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text('Asking the core…', style: TextStyle(color: C.dim, fontSize: 13)),
        )
      else if (l.isEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text('No other device yet.', style: TextStyle(color: C.dim, fontSize: 13)),
        ),
      for (final d in l ?? const <PairedDevice>[]) _tile(d),
      if (_error == null)
        ListTile(
          leading: const Icon(Icons.qr_code_2_rounded, color: C.accent),
          title: const Text('Pair a new device'),
          subtitle: const Text('Show a code to scan in bz-uniai on it'),
          onTap: l == null ? null : _pair,
        ),
    ]);
  }

  Widget _tile(PairedDevice d) => ListTile(
        leading: Stack(clipBehavior: Clip.none, children: [
          const Icon(Icons.smartphone_rounded, color: C.dim),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: d.online ? C.green : C.dim,
                shape: BoxShape.circle,
                border: Border.all(color: C.bg, width: 1.5),
              ),
            ),
          ),
        ]),
        title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [if (d.online) 'connected now', if (d.added != null) 'paired ${_date(d.added!)}'].join(' · '),
          style: const TextStyle(fontSize: 12, color: C.dim),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => v == 'rename' ? _rename(d) : _remove(d),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'remove', child: Text('Remove', style: TextStyle(color: C.red))),
          ],
        ),
      );

  static String _date(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
  }
}

/// A one-time pairing code as a QR and as text. Closes with the new
/// device's name once it has paired, or by itself when the code expires.
class PairCodeDialog extends StatefulWidget {
  const PairCodeDialog({super.key, required this.code, required this.devices, required this.known});
  final PairCode code;
  final Devices devices;
  final Set<String> known; // the devices paired before this code

  @override
  State<PairCodeDialog> createState() => _PairCodeDialogState();
}

class _PairCodeDialogState extends State<PairCodeDialog> {
  StreamSubscription? _sub;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sub = widget.devices.changes.listen((_) => _check());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_left <= Duration.zero) return Navigator.pop(context);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Duration get _left => widget.code.expires.difference(DateTime.now());

  Future<void> _check() async {
    try {
      final l = await widget.devices.list();
      final added = l.where((d) => !widget.known.contains(d.pub)).firstOrNull;
      if (added != null && mounted) Navigator.pop(context, added.name);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final left = _left.isNegative ? Duration.zero : _left;
    final mm = left.inMinutes, ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    return AlertDialog(
      title: const Text('Pair a new device'),
      content: SizedBox(
        width: 280,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: QrImageView(data: widget.code.code, size: 220, padding: EdgeInsets.zero),
          ),
          const SizedBox(height: 14),
          const Text('In bz-uniai on the other device: Add a device, then scan this or paste the code.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: C.dim)),
          const SizedBox(height: 8),
          Text('One device, valid $mm:$ss', style: const TextStyle(fontSize: 12.5, color: C.dim)),
        ]),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Copy code'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: widget.code.code));
            toast(context, 'Code copied');
          },
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
        child: Text(text.toUpperCase(),
            style: const TextStyle(color: C.dim, fontSize: 11.5, letterSpacing: .8, fontWeight: FontWeight.w600)),
      );
}

// Owns its controller: the dialog still builds while it animates out.
class _NameDialog extends StatefulWidget {
  const _NameDialog(this.name);
  final String name;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _c = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: _c,
          autofocus: true,
          maxLength: 60,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: const Text('Save')),
        ],
      );
}
