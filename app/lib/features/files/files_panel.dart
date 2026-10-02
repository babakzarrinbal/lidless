// The files panel: breadcrumbs and the folder listing.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:uniai/net/link.dart';
import 'package:uniai/features/files/editor.dart';
import 'package:uniai/app/theme.dart';
import 'package:uniai/features/files/files.dart';

class Breadcrumbs extends StatefulWidget {
  const Breadcrumbs({super.key, required this.files});
  final Files files;
  @override
  State<Breadcrumbs> createState() => _BreadcrumbsState();
}

class _BreadcrumbsState extends State<Breadcrumbs> {
  final _scroll = ScrollController();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.files,
      builder: (context, _) {
        final f = widget.files;
        final path = f.openPath ?? f.cwd ?? '';
        final home = f.link.home;
        var shown = path;
        var base = '';
        if (path == home || path.startsWith('$home/')) {
          shown = '~${path.substring(home.length)}';
          base = home;
        }
        final parts = shown.split('/').where((s) => s.isNotEmpty).toList();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
        final crumbs = <Widget>[];
        var acc = base.isEmpty ? '' : base;
        for (var i = 0; i < parts.length; i++) {
          final p = parts[i];
          if (!(i == 0 && p == '~')) acc = '$acc/$p';
          final target = i == 0 && p == '~' ? home : acc;
          final last = i == parts.length - 1;
          if (i > 0 || base.isEmpty) {
            crumbs.add(const Icon(Icons.chevron_right_rounded, size: 16, color: C.dim));
          }
          crumbs.add(InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: last || f.openPath != null ? null : () => f.go(target),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(p,
                  style: TextStyle(
                    fontSize: 13,
                    color: last ? C.text : C.dim,
                    fontWeight: last ? FontWeight.w600 : FontWeight.w400,
                  )),
            ),
          ));
        }
        if (parts.isEmpty) crumbs.add(const Text('/', style: TextStyle(fontSize: 13)));
        return SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: Row(children: crumbs),
        );
      },
    );
  }
}

class FilesPanel extends StatelessWidget {
  const FilesPanel({
    super.key,
    required this.files,
    required this.fontSize,
    required this.onFocus,
    required this.onCdInTerminal,
  });
  final Files files;
  final double fontSize;
  final VoidCallback onFocus;
  final void Function(String dir) onCdInTerminal;

  Link get link => files.link;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: files,
      builder: (context, _) {
        if (files.openPath != null) {
          return EditorView(
            key: files.editorKey,
            link: link,
            path: files.openPath!,
            fontSize: fontSize,
            onFocus: onFocus,
            onClose: files.closeEditor,
          );
        }
        return _browser(context);
      },
    );
  }

  Widget _browser(BuildContext context) {
    final list = files.visible;
    return Column(children: [
      Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: C.line))),
        child: Row(children: [
          IconButton(
            tooltip: 'Up',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_upward_rounded, size: 20),
            onPressed: files.cwd == '/' ? null : files.up,
          ),
          IconButton(
            tooltip: 'Session folder',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.folder_special_rounded, size: 20),
            onPressed: () => files.go(files.root),
          ),
          const Spacer(),
          if (files.loading)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                  width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          IconButton(
            tooltip: 'New file',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.note_add_rounded, size: 20),
            onPressed: () => _create(context, folder: false),
          ),
          IconButton(
            tooltip: 'New folder',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.create_new_folder_rounded, size: 20),
            onPressed: () => _create(context, folder: true),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, size: 20),
            onSelected: (v) {
              if (v == 'hidden') files.toggleHidden();
              if (v == 'refresh') files.refresh();
              if (v == 'cd' && files.cwd != null) onCdInTerminal(files.cwd!);
              if (v == 'path' && files.cwd != null) _copyText(context, files.cwd!);
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                  value: 'hidden', checked: files.showHidden, child: const Text('Hidden files')),
              const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
              const PopupMenuItem(value: 'cd', child: Text('Open in terminal')),
              const PopupMenuItem(value: 'path', child: Text('Copy folder path')),
            ],
          ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: files.refresh,
          child: files.error != null
              ? ListView(children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(children: [
                      const Icon(Icons.lock_outline_rounded, color: C.dim, size: 32),
                      const SizedBox(height: 8),
                      Text(files.error!, textAlign: TextAlign.center,
                          style: const TextStyle(color: C.dim)),
                      if (files.error!.contains('not permitted'))
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'macOS protects this folder. Allow it once on the Mac: '
                            'System Settings → Privacy & Security → Full Disk Access → uniai.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: C.dim, fontSize: 12)),
                        ),
                    ]),
                  ),
                ])
              : ListView.builder(
                  itemCount: list.length + (files.truncated ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == list.length) {
                      return const ListTile(
                          dense: true,
                          title: Text('Only the first 5000 entries are shown',
                              style: TextStyle(color: C.dim)));
                    }
                    return _tile(context, list[i]);
                  },
                ),
        ),
      ),
    ]);
  }

  Widget _tile(BuildContext context, Entry e) {
    final (icon, color) = fileIcon(e.name, dir: e.dir);
    final path = joinPath(files.cwd!, e.name);
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      leading: Icon(icon, color: color, size: 22),
      title: Text(e.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 14,
              color: e.name.startsWith('.') ? C.dim : C.text,
              fontStyle: e.link ? FontStyle.italic : FontStyle.normal)),
      subtitle: Text(
        e.dir ? ago(e.mtime) : '${humanSize(e.size)} · ${ago(e.mtime)}',
        style: const TextStyle(fontSize: 11.5, color: C.dim),
      ),
      trailing: e.dir ? const Icon(Icons.chevron_right_rounded, size: 18) : null,
      onTap: () => e.dir ? files.go(path) : files.open(path),
      onLongPress: () => _actions(context, e, path),
    );
  }

  void _copyText(BuildContext context, String s) {
    Clipboard.setData(ClipboardData(text: s));
    HapticFeedback.selectionClick();
    toast(context, 'Copied: $s');
  }

  Future<void> _actions(BuildContext context, Entry e, String path) async {
    HapticFeedback.selectionClick();
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(e.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
          ),
          ListTile(
              leading: const Icon(Icons.content_copy_rounded),
              title: const Text('Copy path'),
              onTap: () => Navigator.pop(ctx, 'path')),
          ListTile(
              leading: const Icon(Icons.terminal_rounded),
              title: Text(e.dir ? 'Open in terminal' : 'cd to its folder in terminal'),
              onTap: () => Navigator.pop(ctx, 'cd')),
          ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: C.red),
              title: const Text('Delete', style: TextStyle(color: C.red)),
              subtitle: e.dir ? const Text('Only empty folders') : null,
              onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!context.mounted || a == null) return;
    switch (a) {
      case 'path':
        _copyText(context, path);
      case 'cd':
        onCdInTerminal(e.dir ? path : files.cwd!);
      case 'rename':
        final name = await _ask(context, 'Rename', e.name, 'Rename');
        if (name == null || name == e.name || !context.mounted) return;
        await _run(context, () => link.call('fs.rename', {'path': path, 'to': joinPath(files.cwd!, name)}));
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${e.name}?'),
            content: const Text('This cannot be undone (it does not go to the Trash).'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: C.red),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Delete')),
            ],
          ),
        );
        if (ok == true && context.mounted) {
          await _run(context, () => link.call('fs.delete', {'path': path}));
        }
    }
  }

  Future<void> _create(BuildContext context, {required bool folder}) async {
    if (files.cwd == null) return;
    final name = await _ask(context, folder ? 'New folder' : 'New file', '', 'Create');
    if (name == null || !context.mounted) return;
    final path = joinPath(files.cwd!, name);
    final ok = await _run(context,
        () => link.call(folder ? 'fs.mkdir' : 'fs.create', {'path': path}));
    if (ok && !folder) files.open(path);
  }

  Future<bool> _run(BuildContext context, Future<dynamic> Function() f) async {
    try {
      await f();
      await files.refresh();
      return true;
    } catch (e) {
      if (context.mounted) toast(context, '$e', error: true);
      return false;
    }
  }

  static Future<String?> _ask(
      BuildContext context, String title, String initial, String action) {
    final c = TextEditingController(text: initial);
    final dot = initial.lastIndexOf('.');
    c.selection = TextSelection(
        baseOffset: 0, extentOffset: dot > 0 ? dot : initial.length);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          autocorrect: false,
          style: const TextStyle(fontFamily: mono, fontSize: 14),
          onSubmitted: (v) => Navigator.pop(ctx, _valid(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, _valid(c.text)), child: Text(action)),
        ],
      ),
    );
  }

  static String? _valid(String s) {
    final v = s.trim();
    if (v.isEmpty || v == '.' || v == '..' || v.contains('/')) return null;
    return v;
  }
}
