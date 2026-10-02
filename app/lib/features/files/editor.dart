// The file editor: view, edit and save one file (fs.*).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/styles/tokyo-night-dark.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uniai/net/link.dart';
import 'package:uniai/app/theme.dart';
import 'package:uniai/features/files/editor_languages.dart';
import 'package:uniai/features/files/editor_find_bar.dart';

class EditorView extends StatefulWidget {
  const EditorView({
    super.key,
    required this.link,
    required this.path,
    required this.fontSize,
    required this.onClose,
    required this.onFocus,
  });
  final Link link;
  final String path;
  final double fontSize;
  final VoidCallback onClose, onFocus;

  @override
  State<EditorView> createState() => EditorViewState();
}

class EditorViewState extends State<EditorView> {
  CodeLineEditingController? _c;
  late final CodeFindController _find;
  final _focus = FocusNode();
  CodeLines? _saved;
  int _mtime = 0;
  String? _problem; // binary / too large / error
  bool _saving = false, _wrap = false, _dirty = false;
  bool _editing = false; // read-only until Edit, so a tap never pops the keyboard
  late final _toolbar = MobileSelectionToolbarController(builder: _toolbarMenu);

  String get name => widget.path.split('/').last;
  bool get dirty => _dirty;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) widget.onFocus();
    });
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _wrap = p.getBool('wrap') ?? true);
    });
    _load();
  }

  @override
  void dispose() {
    _c?.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.link.call('fs.read', {'path': widget.path}) as Map;
      if (!mounted) return;
      _mtime = (r['mtime'] as num).toInt();
      if (r['tooLarge'] == true) {
        setState(() => _problem =
            'This file is ${humanSize((r['size'] as num).toInt())} — too large to edit on the phone (limit 4 MB).');
        return;
      }
      if (r['binary'] == true) {
        setState(() => _problem = 'This is a binary file.');
        return;
      }
      final old = _c;
      final c = CodeLineEditingController.fromText(r['text'] as String);
      _find = CodeFindController(c);
      c.addListener(_changed);
      setState(() {
        _c = c;
        _saved = c.codeLines;
        _dirty = false;
        _problem = null;
      });
      old?.dispose();
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    }
  }

  void _setEditing(bool on) {
    setState(() => _editing = on);
    if (on) {
      // Focus after the rebuild so the editor opens its input connection.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focus.unfocus();
        _focus.requestFocus();
      });
    } else {
      _focus.unfocus();
    }
  }

  void _changed() {
    final d = !identical(_c!.codeLines, _saved);
    if (d != _dirty) setState(() => _dirty = d);
  }

  Future<void> save({bool force = false}) async {
    final c = _c;
    if (c == null || _saving) return;
    setState(() => _saving = true);
    final lines = c.codeLines;
    try {
      final r = await widget.link.call('fs.write', {
        'path': widget.path,
        'text': c.text,
        'mtime': force ? 0 : _mtime,
      }) as Map;
      _mtime = (r['mtime'] as num).toInt();
      _saved = lines;
      HapticFeedback.lightImpact();
      if (mounted) {
        setState(() => _dirty = !identical(c.codeLines, _saved));
        toast(context, 'Saved $name');
      }
    } on RpcError catch (e) {
      if (!mounted) return;
      if (e.code == 'conflict') {
        await _conflict(e.message);
      } else {
        toast(context, 'Not saved: ${e.message}', error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _conflict(String msg) async {
    final a = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.merge_type_rounded, color: C.amber),
        title: const Text('Changed on the Mac'),
        content: Text('$msg.\n\nOverwrite it with your version, or reload and lose your edits?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'reload'), child: const Text('Reload')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'overwrite'), child: const Text('Overwrite')),
        ],
      ),
    );
    if (a == 'overwrite') {
      _saving = false;
      await save(force: true);
    } else if (a == 'reload') {
      await _load();
    }
  }

  /// Returns true when it is fine to leave the editor.
  Future<bool> confirmClose() async {
    if (!_dirty) return true;
    final a = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Save $name?'),
        content: const Text('You have unsaved changes.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Discard')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (a == 'save') {
      await save();
      return !_dirty;
    }
    return a == 'discard';
  }

  Future<void> close() async {
    if (await confirmClose()) widget.onClose();
  }

  Widget _toolbarMenu({
    required BuildContext context,
    required TextSelectionToolbarAnchors anchors,
    required CodeLineEditingController controller,
    required VoidCallback onDismiss,
    required VoidCallback onRefresh,
  }) {
    void act(VoidCallback f) {
      f();
      onDismiss();
    }

    final sel = !controller.selection.isCollapsed;
    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      children: [
        if (sel) _tb('Cut', () => act(controller.cut)),
        if (sel) _tb('Copy', () => act(controller.copy)),
        _tb('Paste', () => act(controller.paste)),
        _tb('Select all', () {
          controller.selectAll();
          onRefresh();
        }),
      ],
    );
  }

  Widget _tb(String label, VoidCallback onTap) => TextSelectionToolbarTextButton(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        onPressed: onTap,
        child: Text(label),
      );

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final lang = languageFor(widget.path);
    return Column(children: [
      Container(
        height: 40,
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
        child: Row(children: [
          IconButton(
            tooltip: 'Back to files',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
            onPressed: close,
          ),
          Expanded(
            child: Row(children: [
              Flexible(
                child: Text(name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              if (_dirty)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.circle, size: 8, color: C.amber),
                ),
            ]),
          ),
          if (c != null && !_editing)
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => _setEditing(true),
              icon: const Icon(Icons.edit_rounded, size: 17),
              label: const Text('Edit'),
            ),
          if (c != null && _editing)
            IconButton(
              tooltip: 'Done editing',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.keyboard_hide_rounded, size: 20, color: C.accent),
              onPressed: () => _setEditing(false),
            ),
          if (c != null) ...[
            if (_editing) ListenableBuilder(
              listenable: c,
              builder: (_, _) => Row(children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.undo_rounded, size: 20),
                  onPressed: c.canUndo ? c.undo : null,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.redo_rounded, size: 20),
                  onPressed: c.canRedo ? c.redo : null,
                ),
              ]),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.search_rounded, size: 20),
              onPressed: () => _find.value == null ? _find.findMode() : _find.close(),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              onSelected: (v) async {
                switch (v) {
                  case 'wrap':
                    setState(() => _wrap = !_wrap);
                    (await SharedPreferences.getInstance()).setBool('wrap', _wrap);
                  case 'replace':
                    if (!_editing) _setEditing(true);
                    _find.replaceMode();
                  case 'copyall':
                    Clipboard.setData(ClipboardData(text: c.text));
                    if (context.mounted) toast(context, 'Copied the whole file');
                  case 'path':
                    Clipboard.setData(ClipboardData(text: widget.path));
                    if (context.mounted) toast(context, 'Copied: ${widget.path}');
                  case 'reload':
                    if (!_dirty || await confirmClose()) _load();
                }
              },
              itemBuilder: (_) => [
                CheckedPopupMenuItem(value: 'wrap', checked: _wrap, child: const Text('Wrap lines')),
                const PopupMenuItem(value: 'replace', child: Text('Find & replace')),
                const PopupMenuItem(value: 'copyall', child: Text('Copy all')),
                const PopupMenuItem(value: 'path', child: Text('Copy path')),
                const PopupMenuItem(value: 'reload', child: Text('Reload from Mac')),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _saving
                  ? const SizedBox(
                      width: 40,
                      child: Center(
                          child: SizedBox(
                              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))))
                  : FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        backgroundColor: _dirty ? C.accent : null,
                        foregroundColor: _dirty ? C.bg : null,
                      ),
                      onPressed: _dirty ? save : null,
                      child: const Text('Save'),
                    ),
            ),
          ],
        ]),
      ),
      Expanded(
        child: _problem != null
            ? Center(
                child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_problem!, textAlign: TextAlign.center, style: const TextStyle(color: C.dim)),
              ))
            : c == null
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : CodeEditor(
                    controller: c,
                    findController: _find,
                    toolbarController: _toolbar,
                    focusNode: _focus,
                    readOnly: !_editing,
                    wordWrap: _wrap,
                    padding: const EdgeInsets.only(left: 4, right: 10, top: 6, bottom: 40),
                    style: CodeEditorStyle(
                      fontSize: widget.fontSize,
                      fontFamily: mono,
                      fontHeight: 1.35,
                      textColor: const Color(0xFFC0CAF5),
                      backgroundColor: C.bg,
                      selectionColor: C.accent.withValues(alpha: .35),
                      cursorColor: C.accent,
                      cursorLineColor: const Color(0x0DFFFFFF),
                      codeTheme: lang == null
                          ? null
                          : CodeHighlightTheme(
                              languages: {lang.$1: CodeHighlightThemeMode(mode: lang.$2)},
                              theme: tokyoNightDarkTheme,
                            ),
                    ),
                    indicatorBuilder: (context, editingController, chunkController, notifier) => Row(
                      children: [
                        DefaultCodeLineNumber(
                          controller: editingController,
                          notifier: notifier,
                          textStyle: TextStyle(color: C.dim.withValues(alpha: .6), fontSize: widget.fontSize - 2, fontFamily: mono),
                          focusedTextStyle: TextStyle(color: C.text, fontSize: widget.fontSize - 2, fontFamily: mono),
                        ),
                        DefaultCodeChunkIndicator(width: 16, controller: chunkController, notifier: notifier),
                      ],
                    ),
                    findBuilder: (context, controller, readOnly) => EditorFindBar(controller: controller),
                  ),
      ),
    ]);
  }
}
