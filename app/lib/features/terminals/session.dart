// A session (one folder: an agent terminal plus shells, tagged with one id on
// the Mac), its [Activity] dot and the tools a session can run.
import 'package:uniai/features/terminals/term_tab.dart';

/// The coding agents a session can run, by terminal kind.
/// 'cli' is a plain shell as the main window.
const tools = {'claude': 'Claude', 'copilot': 'Copilot', 'cli': 'Terminal', 'vscode': 'VS Code'};

/// A view over the terminals that share a session id: one agent terminal
/// (Claude Code or Copilot) and any number of shells.
class Session {
  Session(this.id, this.dir);
  final String id, dir;
  TermTab? agent;
  final shells = <TermTab>[];

  String get tool => agent?.kind ?? 'claude';
  String get toolName => tools[tool] ?? tool;

  String get name {
    final parts = dir.split('/').where((s) => s.isNotEmpty);
    return parts.isEmpty ? '/' : parts.last;
  }

  Activity get activity {
    final a = agent;
    if (a == null || a.exited) return Activity.closed;
    if (a.working) return Activity.working;
    return a.unread ? Activity.unread : Activity.read;
  }
}

/// A session's dot: green working, blinking blue unread (it stopped or asks
/// something, unseen), white read, gray closed.
enum Activity { working, unread, read, closed }
