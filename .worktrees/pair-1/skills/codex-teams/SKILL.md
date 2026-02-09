---
name: codex-teams
description: Launch and operate Codex multi-agent sessions with real-time inter-agent messaging over a shared local bus. Use when tasks need director-worker collaboration, parallel streams, fast blocker resolution, worktree orchestration, or Claude Teams-style live coordination.
---

# Codex Teams

Codex CLI + tmux split panes + SQLite team bus 기반 멀티 에이전트 스킬.

## Quick Start

1. Install globally:
```bash
./scripts/install_global.sh
```

2. Create team context (`TeamCreate` equivalent):
```bash
codex-teams teamcreate --session codex-fleet --workers 4 --description "Repo task force"
```

3. Run swarm with Codex CLI panes:
```bash
codex-teams run --task "<user task>" --session codex-fleet --dashboard
```

4. Monitor bus directly:
```bash
TEAM_DB=.codex-teams/codex-fleet/bus.sqlite ./scripts/team_tail.sh --all monitor
```

5. Open unified terminal dashboard:
```bash
codex-teams-dashboard --session codex-fleet --repo <repo> --room main
```

6. Send team message (`SendMessage` equivalent):
```bash
codex-teams sendmessage --session codex-fleet --type message --from director --to pair-1 --content "Own reconnect logic"
```

## Runtime Layout

Default `codex-teams run/up` mode:
- tmux session `<session>`
- window `swarm`: `director` + `pair-N` split panes (same TUI)
- window `team-monitor`: full bus tail
- window `team-pulse`: pane activity heartbeat emitter
- optional window `team-dashboard` with `--dashboard`

This gives Claude Teams-style parallel visibility while keeping Codex CLI sessions native.

## TeamCreate/TeamDelete

- `teamcreate` creates/refreshes:
  - `.codex-teams/<session>/team.json`
  - `.codex-teams/<session>/bus.sqlite`
  - room member registrations (`director`, `pair-N`, `system`, `monitor`, `orchestrator`)
- `teamdelete` removes the team folder (or force-kills active tmux session first).

## Message Contract

Roles:
- `director`, `pair-N`, `monitor`, `system`, `orchestrator`

Kinds:
- `task`, `question`, `answer`, `status`, `blocker`, `system`
- `message`, `broadcast`
- `plan_approval_request/response`, `shutdown_request/response`, `permission_request/response`

Full protocol: `references/protocol.md`

## Model Selection

Model precedence (highest first):
1. CLI override (`--model`, `--director-model`, `--worker-model`)
2. Project/user `.codex/config.toml` via `resolve_model.py`
3. Codex profile defaults

## Scripts

- `scripts/team_codex.sh`: main entrypoint (`run/up/status/merge/teamcreate/teamdelete/sendmessage`)
- `scripts/team_codex_ma.sh`: legacy codex-ma backend bridge
- `scripts/team_bus.py`: SQLite bus (`init`, `send`, `tail`, `status`, mailbox/control)
- `scripts/team_mailbox.sh`: unread mailbox + pending control requests
- `scripts/team_control.sh`: plan/shutdown/permission request-response helper
- `scripts/team_dashboard.sh`: single-terminal live dashboard (all tmux panes)
- `scripts/team_pulse.sh`: automatic heartbeat from pane content changes
- `scripts/install_global.sh`: global install + launchers

## IDE Viewer Extension

Use `extensions/antigravity-codex-teams-viewer` to watch tmux pane outputs and bus messages in OpenVSX-based IDEs.

## Legacy Backend

If you need previous codex-ma flow:
```bash
codex-teams-ma run --task "<task>"
```
