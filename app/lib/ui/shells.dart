import 'package:flutter/material.dart';

import '../model/terms.dart';
import '../net/link.dart';
import 'theme.dart';

/// A sheet listing the Mac's shells; pops with the path picked. [selected]
/// is ticked (null: the Mac's default).
Future<String?> pickShell(BuildContext context, Terms terms, {String title = 'Open with', String? selected}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(child: _ShellSheet(terms: terms, title: title, selected: selected)),
    );

class _ShellSheet extends StatelessWidget {
  const _ShellSheet({required this.terms, required this.title, this.selected});
  final Terms terms;
  final String title;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ShellInfo?>(
      future: terms.shellInfo(),
      builder: (context, snap) {
        final info = snap.data;
        Widget body;
        if (snap.hasError) {
          body = Padding(
            padding: const EdgeInsets.all(20),
            child: Text(snap.error is RpcError ? '${snap.error}' : 'Couldn\'t ask the Mac', style: const TextStyle(color: C.red)),
          );
        } else if (snap.connectionState != ConnectionState.done) {
          body = const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        } else if (info == null) {
          body = const Padding(
            padding: EdgeInsets.all(20),
            child: Text('Update Lidless on the Mac to choose the shell: brew upgrade macremote, then brew services restart macremote.',
                style: TextStyle(color: C.dim)),
          );
        } else {
          final sel = selected ?? info.current;
          body = Column(mainAxisSize: MainAxisSize.min, children: [
            for (final s in info.shells)
              ListTile(
                leading: Icon(s == sel ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: s == sel ? C.accent : C.dim),
                title: Text(shellName(s)),
                subtitle: Text([
                  s,
                  if (s == info.current) 'default',
                  if (s == info.login && s != info.current) 'login shell',
                ].join(' · ')),
                onTap: () => Navigator.pop(context, s),
              ),
          ]);
        }
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .7),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              body,
            ]),
          ),
        );
      },
    );
  }
}
