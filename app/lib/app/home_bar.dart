// The top bar (menu, connection dot, folder, Mac status, text size and the
// session's menu) and the banner under it when the link is down.
import 'package:flutter/material.dart';

import 'package:uniai/app/theme.dart';
import 'package:uniai/features/workspaces/new_session.dart' show tildePath;
import 'package:uniai/features/terminals/session.dart';
import 'package:uniai/net/link.dart';

class HomeTopBar extends StatelessWidget {
  const HomeTopBar({
    super.key,
    required this.link,
    required this.cur,
    required this.recent,
    required this.statusBusy,
    required this.font,
    required this.onMenu,
    required this.onStatus,
    required this.onFont,
    required this.onRestart,
    required this.onClose,
  });
  final Link link;
  final Session? cur; // null: the recent page
  final bool recent, statusBusy;
  final double font;
  final VoidCallback onMenu, onStatus;
  final void Function(double delta) onFont;
  final void Function(Session) onRestart, onClose;

  @override
  Widget build(BuildContext context) {
    final cur = this.cur;
    final (color, label) = switch (link.state) {
      LinkState.online => (C.green, 'connected'),
      LinkState.connecting => (C.amber, 'connecting…'),
      LinkState.offline => (C.red, 'offline'),
      LinkState.refused => (C.red, 'refused'),
    };
    return SizedBox(
      height: 52,
      child: Row(children: [
        IconButton(
          tooltip: 'Sessions',
          icon: const Icon(Icons.menu_rounded),
          onPressed: onMenu,
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: color.withValues(alpha: .6), blurRadius: 8)],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cur?.name ?? link.host,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text(
              cur == null ? (recent && link.online ? 'Recent sessions' : label) : '${link.host} · ${tildePath(cur.dir, link.home)}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: C.dim, fontSize: 11.5),
            ),
          ]),
        ),
        IconButton(
          tooltip: 'Mac status',
          icon: statusBusy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.laptop_mac_rounded, size: 21),
          onPressed: link.online ? onStatus : null,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (v) => switch (v) {
            'bigger' => onFont(1),
            'smaller' => onFont(-1),
            'restart' => cur == null ? null : onRestart(cur),
            'close' => cur == null ? null : onClose(cur),
            _ => null,
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: Row(children: [
                const Text('Text size', style: TextStyle(color: C.text)),
                const Spacer(),
                Text('${font.round()}', style: const TextStyle(color: C.dim)),
              ]),
            ),
            const PopupMenuItem(value: 'bigger', child: Text('Larger text  A+')),
            const PopupMenuItem(value: 'smaller', child: Text('Smaller text  A−')),
            if (cur != null) ...[
              const PopupMenuDivider(),
              if (cur.tool != 'cli')
                PopupMenuItem(value: 'restart', child: Text('Run ${cur.tool} --continue')),
              PopupMenuItem(value: 'close', child: Text('Close ${cur.name}…')),
            ],
          ],
        ),
      ]),
    );
  }
}

/// Why the Mac is not connected, with a way to retry.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.link, required this.onUnpair});
  final Link link;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final s = link.state;
    if (s == LinkState.online) return const SizedBox.shrink();
    if (s == LinkState.connecting && link.error == null) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    final refused = s == LinkState.refused;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: (refused ? C.red : C.amber).withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(refused ? Icons.block_rounded : Icons.cloud_off_rounded,
            size: 18, color: refused ? C.red : C.amber),
        const SizedBox(width: 10),
        Expanded(
          child: Text(link.error ?? 'Not connected',
              style: const TextStyle(fontSize: 13), maxLines: 3, overflow: TextOverflow.ellipsis),
        ),
        if (refused)
          TextButton(onPressed: onUnpair, child: const Text('Pair again'))
        else
          TextButton(
            onPressed: s == LinkState.connecting ? null : link.reconnectNow,
            child: Text(s == LinkState.connecting ? 'Retrying…' : 'Retry'),
          ),
      ]),
    );
  }
}
