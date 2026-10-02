// A VS Code Copilot Chat read on the phone (chat.transcript), with a way to
// carry it on in a shared terminal.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uniai/features/chat/chat_messages.dart';
import 'package:uniai/features/chat/chat_tools.dart';
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/features/chat/chat.dart';
import 'package:uniai/net/link.dart';
import 'package:uniai/features/workspaces/new_session.dart' show baseName;
import 'package:uniai/app/logos.dart';
import 'package:uniai/app/theme.dart';

/// A VS Code Copilot Chat on the Mac. Only VS Code can add to it, so the
/// phone reads it (again every few seconds while open; the Mac answers "same"
/// when nothing changed) and offers to carry it on in a shared terminal,
/// where every device and the Mac follow it like any session.
class TranscriptPage extends StatefulWidget {
  const TranscriptPage(
      {super.key, required this.link, required this.id, required this.title, required this.dir, this.onContinue});
  final Link link;
  final String id, title, dir;
  final Future<bool> Function(String tool)? onContinue; // started: true

  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  final _scroll = ScrollController();
  Timer? _every;
  var _items = <ChatEntry>[];
  int _size = 0, _mtime = 0;
  bool _busy = false, _loaded = false, _starting = false;
  String? _error;

  /// Picks the agent, then hands the chat to it in a shared terminal.
  Future<void> _continue() async {
    final tool = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(
                'VS Code\'s chat can only grow inside VS Code. This starts a session in a shared terminal that reads '
                'the chat so far and carries on: every phone and the Mac (uniai attach) see it live.',
                style: TextStyle(color: C.dim, height: 1.4)),
          ),
          for (final t in const ['copilot', 'claude'])
            ListTile(
              leading: ToolLogo(t, size: 22),
              title: Text('Continue with ${tools[t]}'),
              onTap: () => Navigator.pop(ctx, t),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (tool == null || !mounted) return;
    setState(() => _starting = true);
    final ok = await widget.onContinue!(tool);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _starting = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _read();
    _every = Timer.periodic(const Duration(seconds: 3), (_) => _read());
  }

  @override
  void dispose() {
    _every?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    if (_busy || !widget.link.online) return;
    _busy = true;
    try {
      final r = await widget.link.call('chat.transcript', {'session': widget.id, 'size': _size, 'mtime': _mtime});
      if (!mounted || r is! Map || r['same'] == true) return;
      // Read whole each time: keep the tool cards that were open.
      final open = {for (final e in _items) if (e.open) e.id};
      final items = <ChatEntry>[], tools = <String, ChatEntry>{};
      for (final m in (r['items'] as List? ?? const []).cast<Map>()) {
        if (m['k'] == 'result') {
          tools[m['id']]
            ?..result = m['text'] as String? ?? ''
            ..err = m['err'] == true;
          continue;
        }
        final e = ChatEntry.from(m);
        if (e.kind == 'tool') {
          tools[e.id] = e;
          e.open = open.contains(e.id);
        }
        items.add(e);
      }
      setState(() {
        _items = items;
        _size = ((r['size'] as num?) ?? 0).toInt();
        _mtime = ((r['mtime'] as num?) ?? 0).toInt();
        _loaded = true;
        _error = null;
      });
    } on RpcError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.code == 'unknown' ? 'This Mac\'s agent is too old to show VS Code chats: update it.' : e.message);
      if (!_loaded) _every?.cancel();
    } catch (_) {
      // The Mac went away for a moment: the next read tries again.
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
          Text('VS Code · ${baseName(widget.dir)}', style: const TextStyle(fontSize: 12, color: C.dim)),
        ]),
      ),
      bottomNavigationBar: widget.onContinue == null || !_loaded
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                child: FilledButton.icon(
                  onPressed: _starting ? null : _continue,
                  icon: _starting
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.devices_rounded),
                  label: const Text('Continue on all devices'),
                ),
              ),
            ),
      body: !_loaded
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error ?? 'Reading the conversation…',
                    textAlign: TextAlign.center, style: const TextStyle(color: C.dim, height: 1.5)),
              ),
            )
          : ListView.builder(
              controller: _scroll,
              reverse: true,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
              itemCount: items.length,
              itemBuilder: (_, r) {
                final i = items.length - 1 - r, e = items[i];
                final prev = i > 0 ? items[i - 1].kind : '';
                return Padding(
                  key: ObjectKey(e),
                  padding: EdgeInsets.only(top: i == 0 ? 0 : e.kind == 'tool' && prev == 'tool' ? 2.0 : 10.0),
                  child: switch (e.kind) {
                    'user' => ChatUser(e.text),
                    'text' => ChatAnswer(e.text, last: i == items.length - 1 || items[i + 1].kind == 'user'),
                    'tool' => ChatTool(e, onToggle: () => setState(() => e.open = !e.open)),
                    _ => ChatNote(e.text),
                  },
                );
              },
            ),
    );
  }
}
