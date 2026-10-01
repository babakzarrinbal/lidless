import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../model/terms.dart';
import 'theme.dart';

/// Tabs strip for a session's shells, for the shell pane's header.
class TermTabs extends StatelessWidget {
  const TermTabs({super.key, required this.terms, required this.session, required this.onNew});
  final Terms terms;
  final Session session;
  final VoidCallback onNew;

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
        tooltip: 'New shell',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.add_rounded, size: 22),
        onPressed: onNew,
      ),
    ]);
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

/// A session's shell pane body: the active shell tab plus its key bar.
class ShellPanel extends StatefulWidget {
  const ShellPanel({
    super.key,
    required this.terms,
    required this.session,
    required this.fontSize,
    required this.onFocus,
  });
  final Terms terms;
  final Session session;
  final double fontSize;
  final VoidCallback onFocus;

  @override
  State<ShellPanel> createState() => ShellPanelState();
}

class ShellPanelState extends State<ShellPanel> {
  final _surface = GlobalKey<TermSurfaceState>();
  String _draft = '';

  Terms get terms => widget.terms;
  TermTab? get tab => terms.activeShell(widget.session);

  void showKeyboard() {
    if (_surface.currentState?.typing.value == false) _surface.currentState?.toggleKeyboard();
  }

  Future<void> _compose() async {
    final c = TextEditingController(text: _draft);
    final r = await composeSheet(context, c, title: 'Command', runLabel: 'Run');
    if (r == null) {
      _draft = c.text;
      return;
    }
    _draft = '';
    final (text, run) = r;
    if (text.isEmpty && !run) return;
    if (text.contains('\n')) {
      terms.paste(tab, text);
    } else {
      terms.type(tab, text);
    }
    if (run) terms.type(tab, '\r');
  }

  @override
  Widget build(BuildContext context) {
    final t = tab;
    return Column(children: [
      Expanded(
        child: TermSurface(
          key: _surface,
          tab: t,
          fontSize: widget.fontSize,
          onFocus: widget.onFocus,
          empty: terms.link.online ? 'Opening a shell…' : 'Waiting for your Mac…',
        ),
      ),
      KeyBar(keys: [
        // Most used first: what a phone keyboard lacks or hides.
        TypingKey(surface: _surface),
        TKey(icon: Icons.content_paste_rounded, onTap: () => pasteInto(context, terms, t)),
        TKey(icon: Icons.keyboard_return_rounded, onTap: () => terms.type(t, '\r')),
        TKey(label: '^C', color: C.red, onTap: () => terms.type(t, '\x03')),
        TKey(label: 'tab', onTap: () => terms.key(t, TerminalKey.tab)),
        TKey(icon: Icons.keyboard_arrow_up_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowUp)),
        TKey(icon: Icons.keyboard_arrow_down_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowDown)),
        TKey(icon: Icons.edit_note_rounded, color: C.accent, onTap: _compose),
        TKey(label: 'esc', onTap: () => terms.key(t, TerminalKey.escape)),
        TKey(label: '⌃', hint: 'control', active: terms.ctrl, onTap: terms.toggleCtrl),
        TKey(icon: Icons.keyboard_arrow_left_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowLeft)),
        TKey(icon: Icons.keyboard_arrow_right_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowRight)),
        for (final s in ['/', '-', '~', '|', '_', '*', '>', '&', r'$', '`'])
          TKey(label: s, onTap: () => t?.terminal.textInput(s)),
        TKey(icon: Icons.backspace_outlined, repeat: true, onTap: () => terms.key(t, TerminalKey.backspace)),
        TKey(label: '⌥', hint: 'option', active: terms.alt, onTap: terms.toggleAlt),
        TKey(label: '⌘', hint: 'command', active: terms.cmd, onTap: terms.toggleCmd),
        TKey(label: 'home', onTap: () => terms.key(t, TerminalKey.home)),
        TKey(label: 'end', onTap: () => terms.key(t, TerminalKey.end)),
        TKey(label: 'pgup', onTap: () => terms.key(t, TerminalKey.pageUp)),
        TKey(label: 'pgdn', onTap: () => terms.key(t, TerminalKey.pageDown)),
      ]),
    ]);
  }
}

/// The Mac's modifier keys, one-shot: ⌃ control, ⌥ option, ⌘ command.
List<Widget> macMods(Terms terms) => [
      TKey(label: '⌃', hint: 'control', active: terms.ctrl, onTap: terms.toggleCtrl),
      TKey(label: '⌥', hint: 'option', active: terms.alt, onTap: terms.toggleAlt),
      TKey(label: '⌘', hint: 'command', active: terms.cmd, onTap: terms.toggleCmd),
    ];

/// The key bar's keyboard button for a [TermSurface]; lit while typing.
class TypingKey extends StatefulWidget {
  const TypingKey({super.key, required this.surface});
  final GlobalKey<TermSurfaceState> surface;
  @override
  State<TypingKey> createState() => _TypingKeyState();
}

class _TypingKeyState extends State<TypingKey> {
  ValueNotifier<bool>? _n;

  @override
  void initState() {
    super.initState();
    // The surface is built in the same frame; pick up its notifier after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _n = widget.surface.currentState?.typing);
    });
  }

  @override
  Widget build(BuildContext context) {
    final n = _n ?? widget.surface.currentState?.typing;
    Widget key(bool on) => TKey(
          icon: on ? Icons.keyboard_hide_rounded : Icons.keyboard_rounded,
          active: on,
          onTap: () => widget.surface.currentState?.toggleKeyboard(),
        );
    if (n == null) return key(false);
    return ValueListenableBuilder<bool>(valueListenable: n, builder: (_, on, _) => key(on));
  }
}

List<Widget> arrowKeys(Terms terms, TermTab? t) => [
      TKey(icon: Icons.keyboard_arrow_up_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowUp)),
      TKey(icon: Icons.keyboard_arrow_down_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowDown)),
      TKey(icon: Icons.keyboard_arrow_left_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowLeft)),
      TKey(icon: Icons.keyboard_arrow_right_rounded, repeat: true, onTap: () => terms.key(t, TerminalKey.arrowRight)),
    ];

Future<void> pasteInto(BuildContext context, Terms terms, TermTab? t) async {
  final d = await Clipboard.getData(Clipboard.kTextPlain);
  final s = d?.text;
  if (s == null || s.isEmpty) {
    if (context.mounted) toast(context, 'Clipboard is empty');
    return;
  }
  terms.paste(t, s);
}

/// A bottom sheet with a multi-line field: returns (text, run) or null.
Future<(String, bool)?> composeSheet(BuildContext context, TextEditingController c,
    {required String title, required String runLabel}) {
  return showModalBottomSheet<(String, bool)>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: const TextStyle(color: C.dim, fontSize: 13)),
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
                final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
                c.value = v.replaced(sel, s);
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          TextButton(onPressed: () => c.clear(), child: const Text('Clear')),
          const Spacer(),
          OutlinedButton(onPressed: () => Navigator.pop(context, (c.text, false)), child: const Text('Insert')),
          const SizedBox(width: 8),
          FilledButton.icon(
              onPressed: () => Navigator.pop(context, (c.text, true)),
              icon: const Icon(Icons.keyboard_return_rounded, size: 18),
              label: Text(runLabel)),
        ]),
      ]),
    ),
  );
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

class KeyBar extends StatelessWidget {
  const KeyBar({super.key, required this.keys});
  final List<Widget> keys;

  @override
  Widget build(BuildContext context) {
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

class TKey extends StatefulWidget {
  const TKey({
    super.key,
    this.label,
    this.icon,
    required this.onTap,
    this.active = false,
    this.repeat = false,
    this.color,
    this.hint,
  });
  final String? label, hint;
  final IconData? icon;
  final VoidCallback onTap;
  final bool active, repeat;
  final Color? color;

  @override
  State<TKey> createState() => _TKeyState();
}

class _TKeyState extends State<TKey> {
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
    final key = Padding(
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
    return widget.hint == null ? key : Tooltip(message: widget.hint!, child: key);
  }
}
