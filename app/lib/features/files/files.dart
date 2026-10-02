// The files controller for one session: the current folder, its listing
// (fs.list), hidden files, and the file open in the editor.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/features/files/editor.dart';

class Entry {
  final String name;
  final bool dir, link;
  final int size, mtime;
  Entry(Map m)
      : name = m['name'],
        dir = m['dir'] == true,
        link = m['link'] == true,
        size = (m['size'] as num?)?.toInt() ?? 0,
        mtime = (m['mtime'] as num?)?.toInt() ?? 0;
}

String joinPath(String dir, String name) =>
    dir.endsWith('/') ? '$dir$name' : '$dir/$name';

String parentOf(String p) {
  final i = p.lastIndexOf('/');
  return i <= 0 ? '/' : p.substring(0, i);
}

/// The files panel: a folder browser that turns into the editor when a file
/// is open. Each session has its own, starting in the session's folder. The
/// breadcrumbs are built from the same controller for the pane's title bar.
class Files extends ChangeNotifier {
  Files(this.link, {required this.root}) {
    link.addListener(_onLink);
    _onLink();
  }

  final Link link;
  final String root;
  String? cwd;
  List<Entry> entries = [];
  bool loading = false, truncated = false, showHidden = true;
  String? error;
  String? openPath; // file in the editor
  GlobalKey<EditorViewState> editorKey = GlobalKey();
  int _epoch = 0;

  void _onLink() {
    if (!link.online || link.epoch == _epoch) return;
    final first = _epoch == 0;
    _epoch = link.epoch;
    if (first) {
      SharedPreferences.getInstance().then((p) {
        showHidden = p.getBool('hiddenFiles') ?? true;
        go(root);
      });
    } else if (cwd != null) {
      refresh();
    }
  }

  Future<void> go(String path) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final r = await link.call('fs.list', {'path': path}) as Map;
      cwd = r['path'] as String;
      truncated = r['truncated'] == true;
      entries = (r['entries'] as List? ?? []).map((m) => Entry(m as Map)).toList();
    } on RpcError catch (e) {
      if (cwd == null && path != root && path != link.home) return go(link.home);
      error = e.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() => go(cwd ?? link.home);

  void up() {
    if (cwd != null && cwd != '/') go(parentOf(cwd!));
  }

  void toggleHidden() {
    showHidden = !showHidden;
    SharedPreferences.getInstance().then((p) => p.setBool('hiddenFiles', showHidden));
    notifyListeners();
  }

  List<Entry> get visible =>
      showHidden ? entries : entries.where((e) => !e.name.startsWith('.')).toList();

  void open(String path) {
    openPath = path;
    editorKey = GlobalKey();
    notifyListeners();
  }

  /// Back from the editor, asking first about unsaved changes. Returns false
  /// when nothing was open.
  Future<bool> back() async {
    if (openPath == null) return false;
    final e = editorKey.currentState;
    if (e == null || await e.confirmClose()) closeEditor();
    return true;
  }

  void closeEditor() {
    openPath = null;
    notifyListeners();
    refresh();
  }

  @override
  void dispose() {
    link.removeListener(_onLink);
    super.dispose();
  }
}
