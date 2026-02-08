---
name: codex-teams
description: Launch and operate Codex multi-agent sessions with real-time inter-agent messaging over a shared local bus. Use when tasks need director-worker collaboration, parallel streams, fast blocker resolution, codex-ma worktree orchestration, or Claude Teams-style live coordination.
---

# Codex Teams

Run director + workers with live team chat over a local SQLite bus, centered on `codex-ma` orchestration.

## Quick Start

1. Install globally:
```bash
./scripts/install_global.sh
```

2. Run with `codex-ma` bridge (worktrees + real-time bus):
```bash
codex-teams-ma run --task "<user task>" --dashboard
```

3. Monitor all traffic:
```bash
TEAM_DB=.codex-teams/codex-fleet/bus.sqlite ./scripts/team_tail.sh --all monitor
```

4. Open unified terminal dashboard:
```bash
./scripts/team_dashboard.sh --session codex-fleet --room main
```

5. Send direct message:
```bash
TEAM_DB=.codex-teams/codex-fleet/bus.sqlite ./scripts/team_send.sh director pair-1 "Own reconnect logic"
```

## Launch Mode

### codex-ma bridge mode
Use when you want worktree isolation and director-managed merge flow:
```bash
./scripts/team_codex_ma.sh run --task "<task>" --dashboard
```

`--workers`를 지정하지 않으면 오케스트레이터가 작업량을 평가해 pair 수를 2~4 범위로 자동 조정합니다.

This mode:
- launches `codex-ma run` using repo config
- attaches live tail panes to director/worker windows
- adds `team-monitor` window with full bus traffic
- optionally adds `team-dashboard` window (`--dashboard`)
- keeps `codex-ma merge` flow for final integration

## Model Selection

Model can be controlled in three ways (highest precedence first):

1. CLI override
```bash
codex-teams-ma run --task "<task>" --model gpt-5.3-codex
```

2. Role override in config (`.codex/config.toml` or `~/.codex/config.toml`)
```toml
[codex_teams]
director_model = "gpt-5.3-codex"
worker_model = "gpt-5.3-codex"
```

3. Existing Codex profile/default model
```toml
[profiles.director]
model = "gpt-5.3-codex"

[profiles.pair]
model = "gpt-5.3-codex"
```

Resolver script: `scripts/resolve_model.py`.

## Messaging Contract

- Roles: `director`, `worker-N` (or `pair-N` in codex-ma windows)
- Kinds: `task`, `question`, `answer`, `status`, `blocker`, `system`
- Worker cadence: start status, milestone status, completion handoff
- Blocker message must include at least one workaround option

Full protocol: `references/protocol.md`

## AutoTrader Plan Usage

When the user provides the staged AutoTrader Task 00-12 plan, split and run in waves from:
`references/autotrader-task-routing.md`

## Scripts

- `scripts/install_global.sh`: install skill into `~/.codex/skills` and launcher commands
- `scripts/team_codex_ma.sh`: bridge `codex-ma` with real-time team bus
- `scripts/team_bus.py`: SQLite bus (`init`, `send`, `tail`, `status`)
- `scripts/team_send.sh`: sender wrapper
- `scripts/team_tail.sh`: follower wrapper
- `scripts/team_status.sh`: bus summary
- `scripts/team_dashboard.sh`: single-terminal live dashboard (messages + per-window outputs)
- `scripts/resolve_model.py`: layered config model resolver

## IDE Viewer Extension

Use `extensions/antigravity-codex-teams-viewer` to watch the same TUI output inside OpenVSX-based IDEs.

## Failure Handling

- If tmux session already exists, rerun with replacement options.
- If codex-ma config is missing, run `codex-ma init` first.
- If model is unresolved, execution falls back to Codex default config behavior.
