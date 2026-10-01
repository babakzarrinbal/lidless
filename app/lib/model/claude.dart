// What the phone shows around an agent session beyond its terminal: the
// folder's earlier conversations, the slash commands, and plan usage.
import '../net/link.dart';
import 'chat.dart';

class Conversation {
  Conversation.from(Map m)
      : id = m['id'] as String,
        title = m['title'] as String? ?? '',
        prompt = m['prompt'] as String? ?? '',
        mtime = DateTime.fromMillisecondsSinceEpoch(((m['mtime'] as num?) ?? 0).toInt() * 1000),
        size = ((m['size'] as num?) ?? 0).toInt(),
        running = m['running'] == true,
        term = ((m['term'] as num?) ?? 0).toInt(),
        dir = m['dir'] as String? ?? '';
  final String id, title, prompt;
  final String dir; // the folder (the recent list only)
  final DateTime mtime;
  final int size;
  final bool running; // a Claude process has it open
  final int term; // …in this app's terminal with this id (0: elsewhere)

  static Future<List<Conversation>> list(Link link, String dir) async {
    final r = await link.call('chat.sessions', {'dir': dir});
    return [for (final m in (r as List? ?? const []).cast<Map>()) Conversation.from(m)];
  }

  /// The newest conversations of every shared folder.
  static Future<List<Conversation>> recent(Link link) async {
    final r = await link.call('chat.recent', null);
    return [for (final m in (r as List? ?? const []).cast<Map>()) Conversation.from(m)];
  }
}

class SlashCommand {
  const SlashCommand(this.name, this.desc, this.src);
  final String name, desc, src; // src: built-in, user, project, skill

  /// The Mac's commands for a folder and tool, read once a minute at most.
  static Future<List<SlashCommand>> of(Link link, String dir, String kind) async {
    final key = '${link.pairing.room}|$kind|$dir';
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 1)) return hit.$2;
    final r = await link.call('chat.commands', {'dir': dir, 'kind': kind});
    final list = [
      for (final m in (r as List? ?? const []).cast<Map>())
        SlashCommand(m['name'] as String, m['desc'] as String? ?? '', m['src'] as String? ?? ''),
    ];
    _cache[key] = (DateTime.now(), list);
    return list;
  }

  static final _cache = <String, (DateTime, List<SlashCommand>)>{};

  /// The commands for what is typed so far ("/com"): prefix matches first.
  static List<SlashCommand> match(List<SlashCommand> all, String typed) {
    final q = typed.substring(1).toLowerCase();
    final starts = all.where((c) => c.name.toLowerCase().startsWith(q));
    final inside = all.where((c) => !c.name.toLowerCase().startsWith(q) && c.name.toLowerCase().contains(q));
    return [...starts, ...inside];
  }
}

class UsageLimit {
  const UsageLimit(this.key, this.pct, this.resets);
  final String key; // five_hour, seven_day, seven_day_opus…
  final double pct;
  final DateTime? resets;

  String get label => switch (key) {
        'five_hour' => 'Session (5 hours)',
        'seven_day' => 'Weekly, all models',
        'spend_limit' => 'Spend limit',
        'premium' => 'Premium requests, this month',
        _ when key.startsWith('seven_day_') => 'Weekly, ${_title(key.substring(10))}',
        _ => _title(key),
      };

  static String _title(String k) =>
      k.split('_').where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');

  int get order => switch (key) { 'five_hour' => 0, 'seven_day' => 1, _ => 2 };
}

class ClaudeUsage {
  ClaudeUsage.from(Map m)
      : email = (m['account'] as Map?)?['email'] as String? ?? '',
        plan = (m['account'] as Map?)?['plan'] as String? ?? '',
        statusline = m['statusline'] == true,
        at = ((m['at'] as num?) ?? 0) > 0 ? DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt() * 1000) : null,
        limits = _limits(m['limits']),
        tokens = [for (final t in (m['tokens'] as List? ?? const [])) AccountTokens.from(t as Map)],
        copilot = m['copilot'] is Map ? CopilotUsage.from(m['copilot'] as Map) : null;
  final String email, plan;
  final bool statusline; // Claude Code reports to the agent
  final DateTime? at; // when Claude last reported
  final List<UsageLimit> limits;
  final List<AccountTokens> tokens; // the signed-in accounts first
  final CopilotUsage? copilot; // when the Mac's GitHub CLI is signed in
}

List<UsageLimit> _limits(Object? m) => [
      for (final e in ((m as Map?) ?? const {}).entries)
        UsageLimit(
          e.key as String,
          ((e.value as Map)['pct'] as num).toDouble(),
          ((e.value as Map)['resets'] as num? ?? 0) > 0
              ? DateTime.fromMillisecondsSinceEpoch(((e.value as Map)['resets'] as num).toInt() * 1000)
              : null,
        ),
    ]..sort((a, b) => a.order != b.order ? a.order - b.order : a.key.compareTo(b.key));

/// Copilot's one limit: premium requests per month.
class CopilotUsage {
  CopilotUsage.from(Map m)
      : login = m['login'] as String? ?? '',
        plan = m['plan'] as String? ?? '',
        limits = _limits(m['limits']),
        used = (m['used'] as num?)?.round(),
        of = (m['of'] as num?)?.round(),
        unlimited = m['unlimited'] == true,
        ended = m['ended'] == true;
  final String login, plan;
  final List<UsageLimit> limits;
  final int? used, of; // premium requests
  final bool unlimited, ended;
}

/// The tokens one account used, as the Mac counted them from the sessions.
class AccountTokens {
  AccountTokens.from(Map m)
      : tool = m['tool'] as String? ?? '',
        account = m['account'] as String? ?? '',
        current = m['current'] == true,
        used = TokenUse.from(m),
        all = (m['all'] as num?)?.toInt() ?? 0,
        since = _time(m['since']),
        reset = m['reset'] == true,
        last = _time(m['last']);
  final String tool, account;
  final bool current; // signed in now
  final TokenUse used; // since [since]
  final int all; // ever counted
  final DateTime? since, last;
  final bool reset; // [since] is a reset

  String get toolName => tool == 'copilot' ? 'Copilot' : 'Claude';
}

DateTime? _time(Object? s) => ((s as num?) ?? 0) > 0 ? DateTime.fromMillisecondsSinceEpoch((s as num).toInt() * 1000) : null;

/// "3 Sep", or "3 Sep 2025" in another year.
String dayText(DateTime t, [DateTime? now]) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final s = '${t.day} ${months[t.month - 1]}';
  return t.year == (now ?? DateTime.now()).year ? s : '$s ${t.year}';
}

/// "2h 14m", "3d 5h", "12m": how long until a time.
String untilText(DateTime t, [DateTime? now]) {
  final d = t.difference(now ?? DateTime.now());
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inDays}d ${d.inHours % 24}h';
}

/// "5m ago", "3h ago", "2d ago".
String agoText(DateTime t, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}
