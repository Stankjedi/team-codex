---
name: codex-teams
description: Launch and operate Codex multi-agent sessions with real-time inter-agent messaging over a shared local bus. Use when tasks need lead-driven orchestration, adaptive worker scaling, and utility-owned git integration.
---

# Codex Teams

Codex CLI + tmux/in-process + SQLite bus + filesystem mailbox 기반 멀티 에이전트 스킬.

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
codex-teams run --task "<user task>" --session codex-fleet --workers auto --teammate-mode tmux --tmux-layout split --dashboard
```

Git binary override example (utility push/merge path):
```bash
codex-teams run --task "<user task>" --session codex-fleet --git-bin "/mnt/c/Program Files/Git/cmd/git.exe"
```

4. Or run in-process teammates:
```bash
codex-teams run --task "<user task>" --session codex-fleet --teammate-mode in-process --no-attach
```

Or run shared in-process hub (single supervisor process):
```bash
codex-teams run --task "<user task>" --session codex-fleet --teammate-mode in-process-shared --no-attach
```

5. Monitor bus directly:
```bash
TEAM_DB=.codex-teams/codex-fleet/bus.sqlite ./scripts/team_tail.sh --all monitor
```

6. Open unified terminal dashboard:
```bash
codex-teams-dashboard --session codex-fleet --repo <repo> --room main
```

7. Send team message (`SendMessage` equivalent):
```bash
codex-teams sendmessage --session codex-fleet --type message --from lead --to worker-1 --content "Own reconnect logic"
```

## Runtime Layout

`codex-teams run/up` modes:
- `--teammate-mode auto`: 대화형+tmux 가능 시 `tmux`, 그 외 `in-process-shared` 자동 선택
- `--teammate-mode tmux`: tmux 세션에 lead + worker/utility 패널 생성
- `--teammate-mode in-process`: 파일 mailbox 폴링 루프 기반 워커 실행
- `--teammate-mode in-process-shared`: 단일 허브 프로세스에서 다수 워커 루프를 공유 실행
- 기본 `--auto-delegate`: 초기 사용자 요청을 워커별 하위 태스크로 자동 분배
- `--no-auto-delegate`: 리더만 초기 지시를 받고 수동 분배
- `--workers auto`: 태스크 난이도에 따라 `worker pool`을 2~4 범위에서 자동 선택

기본 역할 토폴로지:
- `lead` x 1 (오케스트레이션 전용, 실행 작업 금지)
- `worker` x N (가변)
- `utility` x 1

## Fixed Collaboration Workflow

`run/up` 실행 시 아래 협업 흐름을 기본 계약으로 사용:

1. scope: lead가 범위/리스크 정리
2. delegate: worker-N 분배
3. peer-qa: lead/worker 간 질문/응답을 필요할 때마다 반복
4. on-demand-research: worker가 중간 요청하면 lead가 추가 리서치/재계획 후 해당 worker에 재전달
5. review: lead가 결과 검수 후 승인/재작업 결정
6. handoff: utility-1로 인계 후 push/merge

세션 시작 시 버스에 `workflow-fixed ...` 상태 이벤트를 남겨 추적 가능.

tmux mode layout:
- tmux session `<session>`
- window `swarm`: `lead` + `worker-N` + `utility-1` split panes
- window `team-monitor`: full bus tail
- window `team-pulse`: pane activity heartbeat emitter
- optional window `team-dashboard` with `--dashboard`

This gives Claude Teams-style parallel visibility while keeping Codex CLI sessions native.

## TeamCreate/TeamDelete

- `teamcreate` creates/refreshes:
  - `.codex-teams/<session>/config.json` + `team.json`
  - `.codex-teams/<session>/inboxes/*.json`
  - `.codex-teams/<session>/control.json` (control request lifecycle)
  - `.codex-teams/<session>/state.json` + `runtime.json`
  - `.codex-teams/<session>/bus.sqlite`
  - room member registrations (`lead`, `worker-N`, `utility-1`, `system`, `monitor`, `orchestrator`)
- `teamdelete` removes the team folder (or force-kills active tmux session first).

## Message Contract

Roles:
- `lead`, `worker-N`, `utility-1`, `monitor`, `system`, `orchestrator`

Kinds:
- `task`, `question`, `answer`, `status`, `blocker`, `system`
- `message`, `broadcast`
- `plan_approval_request/response`, `shutdown_request/response`, `permission_request/response`
- `shutdown_approved`, `shutdown_rejected`, `mode_set_request/response`

Control request types are tracked in both SQLite and filesystem (`control.json`) with shared `request_id`.

Full protocol: `references/protocol.md`

## Model Selection

Model precedence (highest first):
1. CLI override (`--model`, `--director-model`, `--worker-model`)
2. Project/user `.codex/config.toml` via `resolve_model.py` (`lead/worker/utility` role keys 지원)
3. Codex profile defaults

## Scripts

- `scripts/team_codex.sh`: main entrypoint (`run/up/status/merge/teamcreate/teamdelete/sendmessage`)
- `scripts/team_codex_ma.sh`: legacy codex-ma backend bridge
- `scripts/team_bus.py`: SQLite bus (`init`, `send`, `tail`, `status`, mailbox/control)
- `scripts/team_fs.py`: filesystem team config/mailbox/state/runtime core
- `scripts/team_mailbox.sh`: unread mailbox + pending control requests
- `scripts/team_control.sh`: plan/shutdown/permission request-response helper
- `scripts/team_dashboard.sh`: single-terminal live dashboard (all tmux panes)
- `scripts/team_pulse.sh`: automatic heartbeat from pane content changes
- `scripts/team_inprocess_agent.py`: in-process teammate poll/execute loop
- `scripts/team_inprocess_hub.py`: shared in-process multi-worker hub loop
- `scripts/install_global.sh`: global install + launchers

## IDE / Terminal Usage

Dashboard extension is removed. Use terminal-first monitoring instead.

- Attach tmux session directly:
```bash
tmux attach -t <session>
```

- Or open unified dashboard:
```bash
codex-teams-dashboard --session <session> --repo <repo> --room main
```

## Legacy Backend

If you need previous codex-ma flow:
```bash
codex-teams-ma run --task "<task>"
```
