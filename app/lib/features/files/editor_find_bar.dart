// The editor's find bar (search, next/previous, replace).
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:uniai/app/theme.dart';

class EditorFindBar extends StatelessWidget implements PreferredSizeWidget {
  const EditorFindBar({super.key, required this.controller});
  final CodeFindController controller;

  @override
  Size get preferredSize => Size.fromHeight(
      controller.value == null ? 0 : (controller.value!.replaceMode ? 96 : 50));

  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    if (v == null) return const SizedBox.shrink();
    final r = v.result;
    final count = r == null || r.matches.isEmpty
        ? (controller.findInputController.text.isEmpty ? '' : '0/0')
        : '${r.index + 1}/${r.matches.length}';
    InputDecoration deco(String hint) => InputDecoration(
          hintText: hint,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        );
    return Container(
      color: C.panel,
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: controller.findInputController,
                focusNode: controller.findInputFocusNode,
                autofocus: true,
                autocorrect: false,
                style: const TextStyle(fontFamily: mono, fontSize: 13),
                decoration: deco('Find'),
                onSubmitted: (_) => controller.nextMatch(),
              ),
            ),
          ),
          SizedBox(
              width: 48,
              child: Text(count, textAlign: TextAlign.center, style: const TextStyle(color: C.dim, fontSize: 12))),
          IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.keyboard_arrow_up_rounded),
              onPressed: controller.previousMatch),
          IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              onPressed: controller.nextMatch),
          IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: controller.close),
        ]),
        if (v.replaceMode)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: controller.replaceInputController,
                    focusNode: controller.replaceInputFocusNode,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: mono, fontSize: 13),
                    decoration: deco('Replace with'),
                  ),
                ),
              ),
              TextButton(onPressed: controller.replaceMatch, child: const Text('Replace')),
              TextButton(onPressed: controller.replaceAllMatches, child: const Text('All')),
            ]),
          ),
      ]),
    );
  }
}
