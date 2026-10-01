// The agent's conversation as chat items, read from Claude Code's transcript
// on the Mac (`chat.read`), plus what only the live screen shows: whether
// Claude is working, and a question it is waiting on.
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../net/link.dart';

class ChatEntry {
  ChatEntry(this.kind, {this.id = '', this.name = '', this.text = '', this.detail = ''});
  final String kind; // user, text, tool, note
  final String id, name, text, detail;
  String? result; // a tool's output, once it has finished
  bool err = false;
  bool open = false; // a tool card's details are shown

  factory ChatEntry.from(Map m) => ChatEntry(m['k'] as String,
      id: m['id'] as String? ?? '',
      name: m['name'] as String? ?? '',
      text: m['text'] as String? ?? '',
      detail: m['detail'] as String? ?? '');
}

class ChatLog extends ChangeNotifier {
  final items = <ChatEntry>[];
  final _tools = <String, ChatEntry>{};
  String path = ''; // the transcript's file name; '' until Claude has one
  int next = 0;
  bool loaded = false;
  bool _busy = false;

  Future<void> poll(Link link, int term) async {
    if (_busy || !link.online) return;
    _busy = true;
    try {
      final r = await link.call('chat.read', {'id': term, 'from': next, 'path': path});
      if (r is Map) apply(r);
    } catch (_) {
      // The terminal ended or the Mac went away; the next poll tries again.
    } finally {
      _busy = false;
    }
  }

  void apply(Map r) {
    final reset = r['reset'] == true || r['path'] != path;
    if (reset) {
      items.clear();
      _tools.clear();
    }
    path = r['path'] as String? ?? '';
    next = (r['next'] as num?)?.toInt() ?? 0;
    var changed = reset || !loaded;
    for (final m in (r['items'] as List? ?? const []).cast<Map>()) {
      if (m['k'] == 'result') {
        final t = _tools[m['id']];
        if (t == null) continue; // its call is before what was read
        t.result = m['text'] as String? ?? '';
        t.err = m['err'] == true;
      } else {
        final e = ChatEntry.from(m);
        if (e.kind == 'tool') _tools[e.id] = e;
        items.add(e);
      }
      changed = true;
    }
    loaded = true;
    if (changed) notifyListeners();
  }
}

/// What the agent's screen says right now, beyond the transcript.
class LiveScreen {
  const LiveScreen({this.status, this.question, this.options = const []});
  final String? status; // "✻ Thinking… (12s · esc to interrupt)" while working
  final String? question;
  final List<(String, String)> options; // (key to type, label)

  bool get asking => options.isNotEmpty;

  static final _option = RegExp(r'^\s*(❯\s*)?(\d)\.\s+(.+?)\s*$');
  static final _border = RegExp(r'^[\s│┃|╭╮╰╯─━┌┐└┘]+|[\s│┃|╭╮╰╯─━┌┐└┘]+$');

  static LiveScreen of(Terminal t) {
    final b = t.buffer;
    final lines = [
      for (var i = (b.height - t.viewHeight).clamp(0, b.height); i < b.height; i++)
        b.lines[i].getText().replaceAll(_border, ''),
    ];
    String? status;
    for (final l in lines) {
      if (l.contains('esc to interrupt')) status = l.trim();
    }
    // A choice Claude is waiting on: numbered options, one marked with ❯.
    // The marker keeps an ordinary numbered list in an answer from counting.
    final opts = <(String, String)>[];
    var first = -1, marked = false;
    for (var i = lines.length - 1; i >= 0; i--) {
      final m = _option.firstMatch(lines[i]);
      if (m != null) {
        opts.insert(0, (m.group(2)!, m.group(3)!));
        marked |= m.group(1) != null;
        first = i;
      } else if (opts.isNotEmpty && lines[i].trim().isNotEmpty) {
        break;
      }
    }
    if (opts.length < 2 || !marked || opts.first.$1 != '1') return LiveScreen(status: status);
    String? question;
    for (var i = first - 1; i >= 0 && question == null; i--) {
      final l = lines[i].trim();
      if (l.isNotEmpty) question = l;
    }
    return LiveScreen(status: status, question: question, options: opts);
  }
}
