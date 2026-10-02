// A terminal's right-click menu (Copy / Paste / Select all) and selecting
// everything. term_select.dart opens it. See README.md.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:uniai/features/terminals/term_tab.dart';

/// The menu at [at] (global) over [t]; Copy calls [onCopy].
Future<void> showTermMenu(BuildContext context, Offset at, TermTab t, VoidCallback onCopy) async {
  final hasSel = t.controller.selection != null;
  final clip = await Clipboard.getData(Clipboard.kTextPlain);
  if (!context.mounted) return;
  final paste = !t.exited && (clip?.text ?? '').isNotEmpty;
  final a = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    items: [
      PopupMenuItem(value: 'copy', enabled: hasSel, child: const Text('Copy')),
      PopupMenuItem(value: 'paste', enabled: paste, child: const Text('Paste')),
      const PopupMenuItem(value: 'all', child: Text('Select all')),
    ],
  );
  if (!context.mounted) return;
  switch (a) {
    case 'copy':
      onCopy();
    case 'paste':
      t.terminal.paste(clip!.text!);
    case 'all':
      selectAll(t);
  }
}

/// Selects everything the terminal holds, scrollback included.
void selectAll(TermTab t) {
  reattachLines(t.terminal);
  final b = t.terminal.buffer;
  if (b.lines.length == 0) return;
  t.controller.setSelection(
    b.createAnchor(0, 0),
    b.createAnchor(b.viewWidth, b.lines.length - 1),
  );
}
