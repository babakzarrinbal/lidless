# internal/shellenv

The environment for children the core starts on a person's behalf (holders'
shells, `claude`, `copilot`, the usage probes).

Entry point: `Env()`.

Test: `./dev.sh go build ./...` (tiny; callers' tests cover it).

Traps: it strips `UNIAI_TERM` and the launching terminal's `TERM*`; the
holder sets `UNIAI_TERM` itself after calling it. A holder from an older build
keeps its own environment: this only affects new children.
