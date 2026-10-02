// The chat's rows for tool calls: one compact row that opens to the command,
// the diff and the output.
import 'package:flutter/material.dart';
import 'package:uniai/features/chat/chat_messages.dart';
import 'package:uniai/features/chat/chat.dart';
import 'package:uniai/app/theme.dart';

const _toolIcons = {
  'Bash': Icons.terminal_rounded,
  'Read': Icons.description_outlined,
  'Write': Icons.note_add_outlined,
  'Edit': Icons.edit_outlined,
  'MultiEdit': Icons.edit_outlined,
  'NotebookEdit': Icons.edit_outlined,
  'Grep': Icons.search_rounded,
  'Glob': Icons.folder_open_outlined,
  'WebFetch': Icons.public_rounded,
  'WebSearch': Icons.travel_explore_rounded,
  'Task': Icons.account_tree_outlined,
  'Agent': Icons.account_tree_outlined,
  'TodoWrite': Icons.checklist_rounded,
};

class ChatTool extends StatelessWidget {
  const ChatTool(this.e, {super.key, required this.onToggle, this.onToShell});
  final ChatEntry e;
  final VoidCallback onToggle;
  final ValueChanged<String>? onToShell;

  @override
  Widget build(BuildContext context) {
    final done = e.result != null;
    final Widget state = !done
        ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: C.amber))
        : Icon(e.err ? Icons.close_rounded : Icons.check_rounded, size: 14, color: e.err ? C.red : C.green);
    final hasMore = e.detail.isNotEmpty || (e.result?.isNotEmpty ?? false);
    return Container(
      decoration: BoxDecoration(
        color: e.open ? C.panel : null,
        borderRadius: BorderRadius.circular(10),
        border: e.open ? Border.all(color: C.line) : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: hasMore ? onToggle : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(children: [
              SizedBox(width: 16, child: Center(child: state)),
              const SizedBox(width: 8),
              Icon(_toolIcons[e.name] ?? Icons.extension_outlined, size: 16, color: C.violet),
              const SizedBox(width: 6),
              Text(e.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: C.text)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(e.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: mono, fontSize: 12, color: C.dim)),
              ),
              if (hasMore)
                Icon(e.open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: C.dim),
            ]),
          ),
        ),
        if (e.open) ...[
          if (e.detail.isNotEmpty)
            ChatCode(e.detail, diff: e.name.contains('Edit'), onToShell: e.name == 'Bash' ? onToShell : null),
          if (e.result?.isNotEmpty ?? false) ChatCode(e.result!, color: e.err ? C.red : null),
          const SizedBox(height: 6),
        ],
      ]),
    );
  }
}

class ChatCode extends StatelessWidget {
  const ChatCode(this.text, {super.key, this.diff = false, this.color, this.onToShell});
  final String text;
  final bool diff;
  final Color? color;
  final ValueChanged<String>? onToShell; // a command: offer to put it into the terminal

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontFamily: mono, fontSize: 12, height: 1.45, color: C.text);
    final lines = text.split('\n');
    final span = TextSpan(style: style.copyWith(color: color), children: [
      for (var i = 0; i < lines.length; i++)
        TextSpan(
          text: i < lines.length - 1 ? '${lines[i]}\n' : lines[i],
          style: !diff
              ? null
              : lines[i].startsWith('+ ')
                  ? const TextStyle(color: C.green, backgroundColor: Color(0x229ECE6A))
                  : lines[i].startsWith('- ')
                      ? const TextStyle(color: C.red, backgroundColor: Color(0x22F7768E))
                      : null,
        ),
    ]);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 8, 4),
      constraints: const BoxConstraints(maxHeight: 360),
      decoration: BoxDecoration(color: const Color(0xFF0A0E14), borderRadius: BorderRadius.circular(8)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ChatCodeActions(text, onToShell: onToShell),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText.rich(span),
            ),
          ),
        ),
      ]),
    );
  }
}

class ChatNote extends StatelessWidget {
  const ChatNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          const Expanded(child: Divider()),
          Flexible(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(text,
                  textAlign: TextAlign.center,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: mono, fontSize: 11.5, color: C.dim)),
            ),
          ),
          const Expanded(child: Divider()),
        ]),
      );
}
