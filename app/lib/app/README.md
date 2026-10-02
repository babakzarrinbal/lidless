# app: the shell

The screens that hold everything together: Home (Mac list, drawer, session
tabs, recent page), SessionView (one session's terminal, chat and files),
the theme and the logos. Features live in `../features/`.

Entry points: `Home` (home.dart, split into home_bar, home_drawer,
home_recent, home_status), `SessionView`, `SessionFlows` (the dialog flows:
restart, open or resume a conversation, close), `appTheme()`, `C` (colors).

RPC: `chat.handoff`, `chat.stop` (SessionFlows); `sys.status`, `usage`,
`tokens.reset` (home_status). Everything else goes through the feature models.

Tests: `test/app/home_test.dart`.

Traps:
- The package is `uniai`: imports are `package:uniai/...`.
- SessionFlows uses `state.mounted` and `state.context` directly; wrapper
  getters trip `use_build_context_synchronously`.
- Home passes callbacks to its widgets; do not reach back into `_HomeState`.
