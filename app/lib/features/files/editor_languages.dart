// Which highlight language the editor uses for a file, by name or extension.
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

(String, Mode)? languageFor(String path) {
  final name = path.split('/').last.toLowerCase();
  if (name == 'dockerfile' || name.startsWith('dockerfile.')) return ('dockerfile', langDockerfile);
  if (name == 'makefile') return ('makefile', langMakefile);
  if (name.startsWith('.zsh') || name.startsWith('.bash') || name == '.profile') return ('bash', langBash);
  final ext = name.contains('.') ? name.split('.').last : '';
  return switch (ext) {
    'dart' => ('dart', langDart),
    'go' => ('go', langGo),
    'py' => ('python', langPython),
    'js' || 'mjs' || 'cjs' || 'jsx' => ('javascript', langJavascript),
    'ts' || 'tsx' => ('typescript', langTypescript),
    'json' || 'arb' => ('json', langJson),
    'yaml' || 'yml' => ('yaml', langYaml),
    'sh' || 'bash' || 'zsh' => ('bash', langBash),
    'md' || 'markdown' => ('markdown', langMarkdown),
    'kt' || 'kts' || 'gradle' => ('kotlin', langKotlin),
    'swift' => ('swift', langSwift),
    'java' => ('java', langJava),
    'xml' || 'plist' || 'html' || 'svg' || 'xib' || 'storyboard' => ('xml', langXml),
    'css' || 'scss' => ('css', langCss),
    'sql' => ('sql', langSql),
    'ini' || 'toml' || 'conf' || 'cfg' || 'env' || 'properties' => ('ini', langIni),
    'c' || 'h' || 'cc' || 'cpp' || 'hpp' || 'm' || 'mm' => ('cpp', langCpp),
    'rs' => ('rust', langRust),
    'rb' => ('ruby', langRuby),
    'php' => ('php', langPhp),
    'diff' || 'patch' => ('diff', langDiff),
    _ => null,
  };
}
