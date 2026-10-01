import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

class C {
  static const bg = Color(0xFF0D1117);
  static const panel = Color(0xFF12171F);
  static const raised = Color(0xFF1A212B);
  static const line = Color(0xFF262E3A);
  static const text = Color(0xFFE6EDF3);
  static const dim = Color(0xFF8B949E);
  static const accent = Color(0xFF7AA2F7);
  static const green = Color(0xFF9ECE6A);
  static const amber = Color(0xFFE0AF68);
  static const red = Color(0xFFF7768E);
  static const violet = Color(0xFFBB9AF7);
  static const cyan = Color(0xFF7DCFFF);
}

const mono = 'JetBrainsMono';

ThemeData appTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: C.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: C.accent,
    surface: C.panel,
    surfaceContainerHighest: C.raised,
    surfaceContainerHigh: C.raised,
    surfaceContainer: C.panel,
    outlineVariant: C.line,
    error: C.red,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: C.bg,
    dividerColor: C.line,
    splashFactory: InkSparkle.splashFactory,
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: C.raised,
      contentTextStyle: TextStyle(color: C.text),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: C.panel,
      showDragHandle: true,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: C.panel),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.raised,
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
    listTileTheme: const ListTileThemeData(iconColor: C.dim),
  );
}

const termTheme = TerminalTheme(
  cursor: Color(0xFFC0CAF5),
  selection: Color(0x8033467C),
  foreground: Color(0xFFC0CAF5),
  background: C.bg,
  black: Color(0xFF15161E),
  red: Color(0xFFF7768E),
  green: Color(0xFF9ECE6A),
  yellow: Color(0xFFE0AF68),
  blue: Color(0xFF7AA2F7),
  magenta: Color(0xFFBB9AF7),
  cyan: Color(0xFF7DCFFF),
  white: Color(0xFFA9B1D6),
  brightBlack: Color(0xFF545C7E),
  brightRed: Color(0xFFFF899D),
  brightGreen: Color(0xFFB9F27C),
  brightYellow: Color(0xFFFFC777),
  brightBlue: Color(0xFF8DB0FF),
  brightMagenta: Color(0xFFC7A9FF),
  brightCyan: Color(0xFFA4DAFF),
  brightWhite: Color(0xFFE6EDF3),
  searchHitBackground: Color(0xFFE0AF68),
  searchHitBackgroundCurrent: Color(0xFF9ECE6A),
  searchHitForeground: Color(0xFF0D1117),
);

/// Icon and tint for a file name.
(IconData, Color) fileIcon(String name, {bool dir = false}) {
  if (dir) return (Icons.folder_rounded, C.amber);
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'dart' || 'go' || 'py' || 'js' || 'ts' || 'tsx' || 'jsx' || 'kt' ||
    'swift' || 'java' || 'rs' || 'c' || 'h' || 'cpp' || 'rb' || 'php' =>
      (Icons.code_rounded, C.accent),
    'sh' || 'zsh' || 'bash' || 'fish' => (Icons.terminal_rounded, C.green),
    'json' || 'yaml' || 'yml' || 'toml' || 'ini' || 'env' || 'plist' ||
    'xml' || 'conf' || 'cfg' =>
      (Icons.settings_rounded, C.violet),
    'md' || 'txt' || 'rst' || 'log' => (Icons.notes_rounded, C.cyan),
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' || 'heic' =>
      (Icons.image_rounded, C.red),
    'zip' || 'gz' || 'tar' || 'tgz' || 'xz' || 'dmg' || 'apk' || 'ipa' =>
      (Icons.inventory_2_rounded, C.dim),
    _ => (Icons.insert_drive_file_rounded, C.dim),
  };
}

String humanSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1 << 30) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
}

String ago(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

void toast(BuildContext context, String msg, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(
    content: Text(msg),
    duration: Duration(milliseconds: error ? 3500 : 1600),
    backgroundColor: error ? const Color(0xFF3A1D24) : null,
  ));
}

String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
