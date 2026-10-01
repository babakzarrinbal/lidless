import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../model/terms.dart';
import 'theme.dart';

/// Tabs strip for the terminal panel header.
class TermTabs extends StatelessWidget {
  const TermTabs({super.key, required this.terms});
  final Terms terms;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: terms,
      builder: (context, _) => Row(children: [
        Expanded(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 7),
            itemCount: terms.tabs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              final t = terms.tabs[i];
              final sel = i == terms.active;
              return GestureDetector(
                onTap: () => terms.select(i),
                onLongPress: () => _tabMenu(context, t),
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
        IconButton(
          tooltip: 'New terminal',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_rounded, size: 22),
          onPressed: () => terms.open().catchError(
              (e) => context.mounted ? toast(context, '$e', error: true) : null),
        ),
      ]),
    );
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

class TerminalPanel extends StatefulWidget {
  const TerminalPanel({
    super.key,
    required this.terms,
    required this.fontSize,
    required this.onFocus,
  });
  final Terms terms;
  final double fontSize;
  final VoidCallback onFocus;

  @override
  State<TerminalPanel> createState() => TerminalPanelState();
}

class TerminalPanelState extends State<TerminalPanel> {
  final _view = GlobalKey<TerminalViewState>();
  final _focus = FocusNode();
  String _draft = '';

  Terms get terms => widget.terms;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) widget.onFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void showKeyboard() => _view.currentState?.requestKeyboard();

  void _toggleKeyboard() {
    if (_focus.hasFocus && MediaQuery.viewInsetsOf(context).bottom > 0) {
      _view.currentState?.closeKeyboard();
      _focus.unfocus();
    } else {
      showKeyboard();
    }
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final s = d?.text;
    if (s == null || s.isEmpty) {
      if (mounted) toast(context, 'Clipboard is empty');
      return;
    }
    terms.paste(s);
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

  Future<void> _compose() async {
    final c = TextEditingController(text: _draft);
    final r = await showModalBottomSheet<(String, bool)>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 0, 16, 12 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Command',
                  style: TextStyle(color: C.dim, fontSize: 13)),
              const SizedBox(height: 8),
              TextField(
                controller: c,
                autofocus: true,
                minLines: 2,
                maxLines: 8,
                autocorrect: false,
                textCapitalization: TextCapitalization.none,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontFamily: mono, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Type, dictate or paste — edit it here, then run',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste_rounded, size: 20),
                    onPressed: () async {
                      final d = await Clipboard.getData(Clipboard.kTextPlain);
                      final s = d?.text ?? '';
                      final v = c.value;
                      final sel = v.selection.isValid
                          ? v.selection
                          : TextSelection.collapsed(offset: v.text.length);
                      c.value = v.replaced(sel, s);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                TextButton(
                    onPressed: () => c.clear(), child: const Text('Clear')),
                const Spacer(),
                OutlinedButton(
                    onPressed: () => Navigator.pop(context, (c.text, false)),
                    child: const Text('Insert')),
                const SizedBox(width: 8),
                FilledButton.icon(
                    onPressed: () => Navigator.pop(context, (c.text, true)),
                    icon: const Icon(Icons.keyboard_return_rounded, size: 18),
                    label: const Text('Run')),
              ]),
            ]),
      ),
    );
    if (r == null) {
      _draft = c.text;
      return;
    }
    _draft = '';
    final (text, run) = r;
    if (text.isEmpty && !run) return;
    if (text.contains('\n')) {
      terms.paste(text);
    } else {
      terms.type(text);
    }
    if (run) terms.type('\r');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: terms,
      builder: (context, _) {
        final t = terms.current;
        return Column(children: [
          Expanded(
            child: t == null
                ? Center(
                    child: Text(
                        terms.link.online ? 'Opening a shell…' : 'Waiting for your Mac…',
                        style: const TextStyle(color: C.dim)))
                : Stack(children: [
                    Positioned.fill(
                      child: TerminalView(
                        t.terminal,
                        key: _view,
                        controller: t.controller,
                        focusNode: _focus,
                        theme: termTheme,
                        textStyle: TerminalStyle(
                            fontSize: widget.fontSize, fontFamily: mono),
                        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                        deleteDetection: true,
                        cursorType: TerminalCursorType.block,
                        readOnly: t.exited,
                      ),
                    ),
                    Positioned(
                      top: 6,
                      right: 8,
                      child: ListenableBuilder(
                        listenable: t.controller,
                        builder: (context, _) => t.controller.selection == null
                            ? const SizedBox.shrink()
                            : _CopyChip(
                                onCopy: () => _copy(t),
                                onCancel: t.controller.clearSelection),
                      ),
                    ),
                  ]),
          ),
          _KeyBar(
            terms: terms,
            onKeyboard: _toggleKeyboard,
            onPaste: _paste,
            onCompose: _compose,
          ),
        ]);
      },
    );
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

class _KeyBar extends StatelessWidget {
  const _KeyBar({
    required this.terms,
    required this.onKeyboard,
    required this.onPaste,
    required this.onCompose,
  });
  final Terms terms;
  final VoidCallback onKeyboard, onPaste, onCompose;

  @override
  Widget build(BuildContext context) {
    final keys = <Widget>[
      _Key(icon: Icons.keyboard_rounded, onTap: onKeyboard),
      _Key(label: 'esc', onTap: () => terms.key(TerminalKey.escape)),
      _Key(label: 'tab', onTap: () => terms.key(TerminalKey.tab)),
      _Key(label: 'ctrl', active: terms.ctrl, onTap: terms.toggleCtrl),
      _Key(label: 'alt', active: terms.alt, onTap: terms.toggleAlt),
      _Key(icon: Icons.keyboard_arrow_up_rounded, repeat: true, onTap: () => terms.key(TerminalKey.arrowUp)),
      _Key(icon: Icons.keyboard_arrow_down_rounded, repeat: true, onTap: () => terms.key(TerminalKey.arrowDown)),
      _Key(icon: Icons.keyboard_arrow_left_rounded, repeat: true, onTap: () => terms.key(TerminalKey.arrowLeft)),
      _Key(icon: Icons.keyboard_arrow_right_rounded, repeat: true, onTap: () => terms.key(TerminalKey.arrowRight)),
      _Key(label: '^C', color: C.red, onTap: () => terms.type('\x03')),
      _Key(icon: Icons.content_paste_rounded, onTap: onPaste),
      _Key(icon: Icons.edit_note_rounded, color: C.accent, onTap: onCompose),
      for (final s in ['|', '~', '/', '-', '_', '*', '>', '&', r'$', '`'])
        _Key(label: s, onTap: () => terms.current?.terminal.textInput(s)),
      _Key(label: 'home', onTap: () => terms.key(TerminalKey.home)),
      _Key(label: 'end', onTap: () => terms.key(TerminalKey.end)),
      _Key(label: 'pgup', onTap: () => terms.key(TerminalKey.pageUp)),
      _Key(label: 'pgdn', onTap: () => terms.key(TerminalKey.pageDown)),
      _Key(icon: Icons.backspace_outlined, repeat: true, onTap: () => terms.key(TerminalKey.backspace)),
    ];
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: C.panel,
        border: Border(top: BorderSide(color: C.line)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        children: keys,
      ),
    );
  }
}

class _Key extends StatefulWidget {
  const _Key({
    this.label,
    this.icon,
    required this.onTap,
    this.active = false,
    this.repeat = false,
    this.color,
  });
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool active, repeat;
  final Color? color;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  Timer? _t;

  void _start() {
    _t?.cancel();
    _t = Timer.periodic(const Duration(milliseconds: 70), (_) => widget.onTap());
  }

  void _stop() {
    _t?.cancel();
    _t = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.active ? C.bg : (widget.color ?? C.text);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onLongPressStart: widget.repeat ? (_) => _start() : null,
        onLongPressEnd: widget.repeat ? (_) => _stop() : null,
        onLongPressCancel: widget.repeat ? _stop : null,
        child: Material(
          color: widget.active ? C.accent : C.raised,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onTap();
            },
            child: Container(
              constraints: const BoxConstraints(minWidth: 40),
              padding: const EdgeInsets.symmetric(horizontal: 9),
              alignment: Alignment.center,
              child: widget.icon != null
                  ? Icon(widget.icon, size: 20, color: fg)
                  : Text(widget.label!,
                      style: TextStyle(
                          fontFamily: mono,
                          fontSize: 13.5,
                          color: fg,
                          fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
  }
}
