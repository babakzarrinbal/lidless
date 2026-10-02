// Links in an answer: a tap opens one in the browser; a long press (a right
// click on a Mac) adds Open link, Copy link and Copy text to the text menu.
// See README.md.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:uniai/app/theme.dart';

/// What opens a link: the browser (a test swaps it).
Future<bool> Function(Uri) launch = (u) => launchUrl(u, mode: LaunchMode.externalApplication);

/// Opens [href] outside the app; says so when nothing can.
Future<void> openLink(BuildContext context, String href) async {
  final uri = Uri.tryParse(href);
  var ok = false;
  try {
    ok = uri != null && uri.hasScheme && await launch(uri);
  } catch (_) {}
  if (!ok && context.mounted) toast(context, 'Can\'t open $href', error: true);
}

/// The links in answers. The markdown widget hands out a tap recognizer per
/// link and says which link only when one is tapped, so the menu asks a
/// recognizer by tapping it with [_asking] set. One for every answer: the
/// widget keeps the menu builder of the build that parsed the text but calls
/// the newest onTapLink, so both must reach the same object.
final chatLinks = ChatLinks._();

class ChatLinks {
  ChatLinks._();

  bool _asking = false;
  String? _asked;

  /// The markdown widget's onTapLink.
  void onTap(BuildContext context, String? href) {
    if (href == null) return;
    if (_asking) {
      _asked = href;
      return;
    }
    openLink(context, href);
  }

  /// The link whose span holds the whole selection, with its text.
  (String href, String text)? at(EditableTextState s) {
    final sel = s.textEditingValue.selection, text = s.renderEditable.text;
    if (!sel.isValid || text == null) return null;
    final a = text.getSpanForPosition(TextPosition(offset: sel.start));
    final b = sel.isCollapsed ? a : text.getSpanForPosition(TextPosition(offset: sel.end - 1));
    if (a is! TextSpan || !identical(a, b) || a.recognizer is! TapGestureRecognizer) return null;
    _asking = true;
    _asked = null;
    try {
      (a.recognizer as TapGestureRecognizer).onTap?.call();
    } finally {
      _asking = false;
    }
    final href = _asked;
    return href == null ? null : (href, a.text ?? href);
  }

  /// The text menu, with the link's actions first when it is on a link.
  Widget menu(BuildContext context, EditableTextState s) {
    final link = at(s);
    if (link == null) return AdaptiveTextSelectionToolbar.editableText(editableTextState: s);
    final (href, text) = link;
    void done() => s.hideToolbar();
    void copy(String v, String what) {
      Clipboard.setData(ClipboardData(text: v));
      done();
      toast(context, '$what copied');
    }

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: s.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(label: 'Open link', onPressed: () {
          done();
          openLink(context, href);
        }),
        ContextMenuButtonItem(label: 'Copy link', onPressed: () => copy(href, 'Link')),
        ContextMenuButtonItem(label: 'Copy text', onPressed: () => copy(text, 'Text')),
        // The selection is part of the link's text: Copy text covers it.
        ...s.contextMenuButtonItems.where((i) => i.type != ContextMenuButtonType.copy),
      ],
    );
  }
}
