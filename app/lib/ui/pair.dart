import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../net/link.dart';
import '../net/store.dart';
import 'theme.dart';

/// First screen: how to get a pairing code, and the ways to enter it.
class PairScreen extends StatelessWidget {
  const PairScreen({super.key, required this.onCode, this.attempt, this.onCancel, this.onBack});
  final void Function(String code) onCode;
  final Link? attempt; // a pairing in progress
  final VoidCallback? onCancel;
  final VoidCallback? onBack; // pairing another Mac: back to the current one

  Future<void> _paste(BuildContext context) async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text?.trim() ?? '';
    if (!context.mounted) return;
    if (!t.contains('mr1.')) {
      toast(context, 'The clipboard has no pairing code', error: true);
      return;
    }
    onCode(t);
  }

  Future<void> _scan(BuildContext context) async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (code != null) onCode(code);
  }

  @override
  Widget build(BuildContext context) {
    final a = attempt;
    return PopScope(
      canPop: onBack == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onBack?.call();
      },
      child: Scaffold(
        appBar: onBack == null
            ? null
            : AppBar(
                leading: BackButton(onPressed: onBack),
                title: const Text('Add a device'),
              ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      alignment: Alignment.center,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: C.accent.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.terminal_rounded, size: 38, color: C.accent),
                    ),
                    const Text(
                      'bz-uniai',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'A terminal and the files of your Mac, end-to-end encrypted.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: C.dim),
                    ),
                    const SizedBox(height: 32),
                    if (a != null)
                      ListenableBuilder(
                        listenable: a,
                        builder: (context, _) => _Attempt(link: a, onCancel: onCancel),
                      )
                    else ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: C.panel,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: C.line),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('In bz-uniai on your Mac, open Devices → Pair a new device. Or run',
                                style: TextStyle(color: C.dim)),
                            SizedBox(height: 8),
                            SelectableText(
                              'uniai pair',
                              style: TextStyle(fontFamily: mono, fontSize: 16, color: C.green),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Either shows a QR code and a text code, valid for 10 minutes.',
                              style: TextStyle(color: C.dim, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        onPressed: () => _scan(context),
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('Scan QR code'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        onPressed: () => _paste(context),
                        icon: const Icon(Icons.content_paste_rounded),
                        label: const Text('Paste code'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Attempt extends StatelessWidget {
  const _Attempt({required this.link, this.onCancel});
  final Link link;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final refused = link.state == LinkState.refused;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (refused)
              const Icon(Icons.error_outline_rounded, color: C.red)
            else
              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                refused ? 'Pairing refused' : 'Pairing with ${link.pairing.host}…',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        if (link.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10, left: 34),
            child: Text(link.error!, style: TextStyle(color: refused ? C.red : C.dim)),
          ),
        const SizedBox(height: 24),
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: onCancel,
          child: Text(refused ? 'Try another code' : 'Cancel'),
        ),
      ],
    );
  }
}

/// Asks before using a pairing code (it may have come from a link).
Future<String?> confirmPairing(BuildContext context, MacPairing p, String name, {bool replacing = false}) {
  final ctl = TextEditingController(text: name);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.laptop_mac_rounded, color: C.accent),
      title: Text('Pair with ${p.host}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Relay ${p.relay}', style: const TextStyle(color: C.dim, fontSize: 13)),
          Text(
            'Mac key ${p.macPub.substring(0, 16)}…',
            style: const TextStyle(color: C.dim, fontSize: 13, fontFamily: mono),
          ),
          if (replacing)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'This phone is already paired with this Mac; the old pairing is replaced.',
                style: TextStyle(color: C.amber),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: ctl,
            decoration: const InputDecoration(labelText: 'This phone\'s name on the Mac'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctl.text.trim().isEmpty ? name : ctl.text.trim()),
          child: const Text('Pair'),
        ),
      ],
    ),
  );
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _ctl = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('Scan the code on your Mac')),
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _ctl,
            onDetect: (c) {
              if (_done) return;
              for (final b in c.barcodes) {
                final v = b.rawValue;
                if (v != null && v.contains('mr1.')) {
                  _done = true;
                  HapticFeedback.mediumImpact();
                  Navigator.pop(context, v);
                  return;
                }
              }
            },
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: C.accent, width: 3),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
