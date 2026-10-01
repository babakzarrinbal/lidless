// The agent's conversation as chat items, read from Claude Code's transcript
// on the Mac (`chat.read`), plus what only the live screen shows: whether
// Claude is working, and a question it is waiting on.
import 'dart:async';

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
  final queued = <String>[]; // typed while Claude works, not taken in yet
  final _local = <String>{}; // sent from here, not in the transcript yet
  final _tools = <String, ChatEntry>{};
  final _results = <String, (String, bool)>{}; // results whose call is before what was read
  String path = ''; // the transcript's file name; '' until Claude has one
  int next = 0;
  int? start; // where the earliest item begins in the transcript; null: an agent that can't read back
  bool _older = false;
  bool loaded = false;
  bool _busy = false;
  ContextUse? ctx; // how full Claude's context window is, once it has answered
  TokenUse? used; // the tokens this conversation used, and on which accounts

  bool _gone = false; // the terminal ended: nothing more to read

  Future<void> poll(Link link, int term) async {
    if (_busy || _gone || !link.online) return;
    _busy = true;
    try {
      final r = await link.call('chat.read', {'id': term, 'from': next, 'path': path});
      if (r is Map) apply(r);
    } on RpcError catch (e) {
      _gone = e.code == 'gone'; // else the Mac went away for a moment: the next poll tries again
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  /// Earlier messages than the first one shown, back to the conversation's start.
  bool get hasOlder => (start ?? 0) > 0;

  /// Reads the page before the earliest item (a page with nothing to show,
  /// a huge line say, reads on). False: nothing more, or it failed.
  Future<bool> older(Link link, int term) async {
    if (_older || !hasOlder || !link.online) return false;
    _older = true;
    try {
      for (var i = 0; i < 8 && hasOlder; i++) {
        final at = start, had = path;
        final r = await link.call('chat.older', {'id': term, 'before': at, 'path': had});
        // The conversation was read again meanwhile: this page is not before it.
        if (r is! Map || start != at || path != had || r['path'] != had) return false;
        if (prepend(r) > 0) return true;
      }
      return false;
    } on RpcError {
      start = null; // gone, or an agent without chat.older
      notifyListeners();
      return false;
    } catch (_) {
      return false;
    } finally {
      _older = false;
    }
  }

  /// Puts a page read back before the items; how many it added.
  int prepend(Map r) {
    final page = <ChatEntry>[];
    for (final m in (r['items'] as List? ?? const []).cast<Map>()) {
      switch (m['k']) {
        case 'queued' || 'unqueue':
          break; // long taken in
        case 'result':
          final i = page.lastIndexWhere((e) => e.kind == 'tool' && e.id == m['id']);
          final res = (m['text'] as String? ?? '', m['err'] == true);
          if (i < 0) {
            _results[m['id'] as String? ?? ''] = res; // its call is further back still
          } else {
            page[i]
              ..result = res.$1
              ..err = res.$2;
          }
        default:
          final e = ChatEntry.from(m);
          if (e.kind == 'tool') {
            if (_results.remove(e.id) case (final text, final err)) {
              e.result = text;
              e.err = err;
            }
            _tools[e.id] = e;
          }
          page.add(e);
      }
    }
    start = (r['start'] as num?)?.toInt() ?? 0;
    items.insertAll(0, page);
    notifyListeners();
    return page.length;
  }

  /// Reads up to the transcript's end (a long one comes in chunks).
  Future<void> catchUp(Link link, int term) async {
    for (var i = 0; i < 8; i++) {
      while (_busy) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final was = next;
      await poll(link, term);
      if (next == was && loaded) return;
    }
  }

  /// Shows a message sent from the phone at once, until the transcript has
  /// it (as a message or queued). One the transcript never shows as typed (a
  /// / command, say) goes away by itself.
  void sent(String text) {
    final s = text.trim();
    if (s.isEmpty || s.startsWith('/') || s.startsWith('!') || queued.contains(s)) return;
    queued.add(s);
    _local.add(s);
    notifyListeners();
    Timer(const Duration(seconds: 20), () {
      if (_local.remove(s) && queued.remove(s)) notifyListeners();
    });
  }

  /// Sent from the phone but not yet seen in the transcript.
  bool sending(String text) => _local.contains(text);

  void apply(Map r) {
    if ((r['path'] as String? ?? '').isEmpty && path.isNotEmpty) {
      // The Mac lost sight of Claude's file for a moment (or Claude quit):
      // keep the conversation on screen rather than blank it.
      return;
    }
    final reset = r['reset'] == true || r['path'] != path;
    if (reset) {
      items.clear();
      queued
        ..clear()
        ..addAll(_local);
      _tools.clear();
      _results.clear();
      start = (r['start'] as num?)?.toInt();
    }
    path = r['path'] as String? ?? '';
    next = (r['next'] as num?)?.toInt() ?? 0;
    var changed = reset || !loaded;
    for (final m in (r['items'] as List? ?? const []).cast<Map>()) {
      final text = m['text'] as String? ?? '';
      if (m['k'] == 'queued') {
        if (!_local.remove(text)) queued.add(text);
      } else if (m['k'] == 'unqueue') {
        // Sent or dropped: the matching one, or the oldest when it doesn't say.
        final i = text.isEmpty ? (queued.isEmpty ? -1 : 0) : queued.indexOf(text);
        if (i >= 0) queued.removeAt(i);
      } else if (m['k'] == 'result') {
        final t = _tools[m['id']];
        if (t == null) {
          // Its call is before what was read: kept for when scrolling back reaches it.
          _results[m['id'] as String? ?? ''] = (m['text'] as String? ?? '', m['err'] == true);
          continue;
        }
        t.result = m['text'] as String? ?? '';
        t.err = m['err'] == true;
      } else {
        final e = ChatEntry.from(m);
        if (e.kind == 'tool') _tools[e.id] = e;
        if (e.kind == 'user') {
          queued.remove(e.text);
          _local.remove(e.text);
        }
        items.add(e);
      }
      changed = true;
    }
    if (r['ctx'] case final Map c) {
      final u = ContextUse((c['tokens'] as num).toInt(), (c['size'] as num).toInt(), c['model'] as String? ?? '');
      if (u != ctx) changed = true;
      ctx = u;
    }
    if (r['used'] case final Map m) {
      final u = TokenUse.from(m);
      if (u != used) changed = true;
      used = u;
    }
    loaded = true;
    if (changed) notifyListeners();
  }
}

class ContextUse {
  const ContextUse(this.tokens, this.size, this.model);
  final int tokens, size;
  final String model;
  double get fraction => size <= 0 ? 0 : (tokens / size).clamp(0, 1).toDouble();

  @override
  bool operator ==(Object other) =>
      other is ContextUse && other.tokens == tokens && other.size == size && other.model == model;
  @override
  int get hashCode => Object.hash(tokens, size, model);
}

/// Tokens used: fresh input, output, and the cached input read and written.
class TokenUse {
  const TokenUse(this.input, this.output, this.cacheRead, this.cacheWrite, [this.accounts = const []]);

  /// {used: {in, out, cr, cw}, accounts: […]}, or the sums alone.
  factory TokenUse.from(Map m) {
    final u = (m['used'] as Map?) ?? m;
    int n(String k) => (u[k] as num?)?.toInt() ?? 0;
    return TokenUse(n('in'), n('out'), n('cr'), n('cw'), [...?(m['accounts'] as List?)?.cast<String>()]);
  }

  final int input, output, cacheRead, cacheWrite;
  final List<String> accounts;
  int get total => input + output + cacheRead + cacheWrite;

  @override
  bool operator ==(Object other) =>
      other is TokenUse &&
      other.input == input &&
      other.output == output &&
      other.cacheRead == cacheRead &&
      other.cacheWrite == cacheWrite &&
      other.accounts.join('\n') == accounts.join('\n');
  @override
  int get hashCode => Object.hash(input, output, cacheRead, cacheWrite, accounts.join('\n'));
}

/// "127k", "1.2M", "3B": token counts the way Claude Code prints them.
String tokenCount(int n) {
  if (n >= 1000000000) return '${(n / 1e9).toStringAsFixed(n >= 10000000000 ? 0 : 1)}B';
  if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(n >= 10000000 ? 0 : 1)}M';
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$n';
}

/// The working line's parts: "✶ Pondering… (esc to interrupt · 12s · ↓ 1.2k tokens)"
/// → ("Pondering…", "12s · ↓ 1.2k tokens").
(String, String) workingParts(String status) {
  var s = status.replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '');
  var meta = '';
  final i = s.indexOf('(');
  if (i >= 0) {
    meta = s.substring(i + 1).replaceAll(')', '');
    s = s.substring(0, i);
  }
  meta = meta
      .split('·')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty && !p.contains('esc to interrupt'))
      .join(' · ');
  return (s.trim(), meta);
}

/// What the agent's screen says right now, beyond the transcript.
class LiveScreen {
  const LiveScreen({this.status, this.question, this.options = const []});
  final String? status; // "✻ Thinking… (12s · esc to interrupt)" while working
  final String? question;
  final List<(String, String)> options; // (key to type, label)

  bool get asking => options.isNotEmpty;

  static final _option = RegExp(r'^\s*(❯\s*)?(\d)\.\s+(.+?)\s*$');
  // The spinner while it runs: "✻ Compacting conversation… (8s)" carries no
  // "esc to interrupt"; once done it says "✻ Worked for 12s", with no "…".
  static final _spinner = RegExp(r'^[·✢✳✶✻✽*]\s+\S[^…(]*…');
  static final _border = RegExp(r'^[\s│┃|╭╮╰╯─━┌┐└┘]+|[\s│┃|╭╮╰╯─━┌┐└┘]+$');

  static LiveScreen of(Terminal t) {
    final b = t.buffer;
    final lines = [
      for (var i = (b.height - t.viewHeight).clamp(0, b.height); i < b.height; i++)
        b.lines[i].getText().replaceAll(_border, ''),
    ];
    String? status;
    for (final l in lines) {
      if (l.contains('esc to interrupt') || _spinner.hasMatch(l.trim())) status = l.trim();
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
