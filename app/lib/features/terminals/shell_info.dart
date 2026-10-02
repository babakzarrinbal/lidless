// The shells a Mac offers (/etc/shells), read through shell.list.
/// The shells a Mac offers (/etc/shells) and the one new terminals get.
class ShellInfo {
  ShellInfo.from(Map m)
      : shells = [...((m['shells'] as List?) ?? const []).cast<String>()],
        def = m['default'] as String? ?? '',
        login = m['login'] as String? ?? '';
  final List<String> shells;
  final String def; // set from the phone; empty: the login shell
  final String login; // the account's shell

  String get current => def.isEmpty ? login : def;
}

/// "zsh" for "/bin/zsh".
String shellName(String path) => path.substring(path.lastIndexOf('/') + 1);
