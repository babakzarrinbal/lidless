// The terminal tabs and the terminal surface that draws one terminal.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'package:uniai/features/terminals/term_tab.dart';
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/terminals/terms.dart';
import 'package:uniai/app/theme.dart';

/// Tabs strip for a session's shells, for the shell pane's header.
class TermTabs extends StatelessWidget {
  const TermTabs({super.key, required this.terms, required this.session, required this.onNew, this.onPick});
  final Terms terms;
  final Session session;
  final VoidCallback onNew;
  final VoidCallback? onPick; // hold +: pick the shell

  @override
  Widget build(BuildContext context) {
    final shells = session.shells;
    final cur = terms.activeShell(session);
    return Row(children: [
      Expanded(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 7),
          itemCount: shells.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, i) {
            final t = shells[i];
            final sel = t == cur;
            return GestureDetector(
              onTap: () => terms.selectShell(session, t),
              onLongPress: () => _tabMenu(context, t),
              onSecondaryTap: () => _tabMenu(context, t), // right click on a Mac
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: sel ? C.accent.withValues(alpha: .16) : C.raised,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: sel ? C.accent.withValues(alpha: .5) : Colors.transparent),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    t.exited ? Icons.stop_circle_outlined : Icons.circle,
                    size: t.exited ? 12 : 7,
                    color: t.exited ? C.dim : C.green,
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 130),
                    child: Text(
                      t.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: sel ? C.text : C.dim,
                        fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
      // No tooltip on +: it would take the long press.
      GestureDetector(
        onSecondaryTap: onPick == null ? null : _pick,
        child: IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_rounded, size: 22),
          onPressed: onNew,
          onLongPress: onPick == null ? null : _pick,
        ),
      ),
      if (onPick != null)
        IconButton(
          tooltip: 'New shell with… (bash, zsh)',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 28),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.arrow_drop_down_rounded, size: 22),
          onPressed: _pick,
        ),
    ]);
  }

  void _pick() {
    HapticFeedback.selectionClick();
    onPick!();
  }

  Future<void> _tabMenu(BuildContext context, TermTab t) async {
    HapticFeedback.selectionClick();
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(context, 'rename')),
          ListTile(
              leading: const Icon(Icons.close_rounded, color: C.red),
              title: Text(t.exited ? 'Remove tab' : 'Close (ends the shell)'),
              onTap: () => Navigator.pop(context, 'close')),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (a == 'close') {
      terms.close(t);
    } else if (a == 'rename') {
      final c = TextEditingController(text: t.title);
      final name = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Rename terminal'),
          content: TextField(
              controller: c,
              autofocus: true,
              onSubmitted: (v) => Navigator.pop(context, v)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, c.text),
                child: const Text('Rename')),
          ],
        ),
      );
      if (name != null && name.trim().isNotEmpty) terms.rename(t, name.trim());
    }
  }
}

/// One terminal on screen. It is read-only (a tap selects and scrolls but
/// never opens the keyboard) until [TermSurfaceState.toggleKeyboard] turns
/// typing on; hiding the keyboard turns it off again.
class TermSurface extends StatefulWidget {
  const TermSurface({
    super.key,
    required this.tab,
    required this.fontSize,
    required this.onFocus,
    this.empty = '',
  });
  final TermTab? tab;
  final double fontSize;
  final VoidCallback onFocus;
  final String empty;

  @override
  State<TermSurface> createState() => TermSurfaceState();
}

class TermSurfaceState extends State<TermSurface> with WidgetsBindingObserver {
  final _view = GlobalKey<TerminalViewState>();
  final _focus = FocusNode();
  final typing = ValueNotifier(false);
  bool _kbSeen = false; // the keyboard has shown since typing turned on

  bool get _typing => typing.value;
  set _typing(bool v) {
    if (typing.value == v) return;
    typing.value = v;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focus.addListener(() {
      if (_focus.hasFocus) {
        widget.onFocus();
      } else {
        _typing = false;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    typing.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!_typing || !mounted) return;
    final up = View.of(context).viewInsets.bottom > 0;
    if (up) {
      _kbSeen = true;
    } else if (_kbSeen) {
      // Keyboard dismissed (back gesture): back to read-only.
      _typing = false;
    }
  }

  void toggleKeyboard() {
    if (_typing) {
      _view.currentState?.closeKeyboard();
      _focus.unfocus();
      _typing = false;
      return;
    }
    _kbSeen = false;
    _typing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _view.currentState?.requestKeyboard());
  }

  void _copy(TermTab t) {
    final sel = t.controller.selection;
    if (sel == null) return;
    final text = t.terminal.buffer
        .getText(sel)
        .split('\n')
        .map((l) => l.trimRight())
        .join('\n')
        .trimRight();
    Clipboard.setData(ClipboardData(text: text));
    t.controller.clearSelection();
    HapticFeedback.selectionClick();
    toast(context, 'Copied ${text.length} characters');
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tab;
    if (t == null) {
      return Center(child: Text(widget.empty, style: const TextStyle(color: C.dim)));
    }
    return Stack(children: [
      Positioned.fill(
        child: TerminalView(
          t.terminal,
          key: _view,
          controller: t.controller,
          focusNode: _focus,
          theme: termTheme,
          textStyle: TerminalStyle(fontSize: widget.fontSize, fontFamily: mono),
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          deleteDetection: true,
          cursorType: TerminalCursorType.block,
          readOnly: t.exited || !_typing,
        ),
      ),
      Positioned(
        top: 6,
        right: 8,
        child: ListenableBuilder(
          listenable: t.controller,
          builder: (context, _) => t.controller.selection == null
              ? const SizedBox.shrink()
              : _CopyChip(onCopy: () => _copy(t), onCancel: t.controller.clearSelection),
        ),
      ),
    ]);
  }
}

class _CopyChip extends StatelessWidget {
  const _CopyChip({required this.onCopy, required this.onCancel});
  final VoidCallback onCopy, onCancel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: C.raised,
      elevation: 6,
      borderRadius: BorderRadius.circular(22),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton.icon(
          onPressed: onCopy,
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Copy'),
        ),
        IconButton(
          onPressed: onCancel,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
      ]),
    );
  }
}
