---
name: codex-teams
description: Launch and operate Codex multi-agent sessions with real-time inter-agent messaging over a shared local bus. Use when tasks need lead-driven orchestration, adaptive worker scaling, and utility-owned git integration.
---

# Codex Teams

Windows host + WSL 전용.
Codex CLI + tmux/in-process + SQLite bus + filesystem mailbox 기반 멀티 에이전트 스킬.

## Mandatory Collaboration Policy

`$codex-teams` 스킬이 호출되면 작업은 **반드시 멀티에이전트 협업 방식**으로 수행해야 한다.

- 기본 실행 형태: `lead + worker-N + utility-1` 협업 토폴로지
- 기본 백엔드: `in-process-shared` (옵션 미지정 시)
- 금지: 스킬 호출 후 단일 에이전트 단독 구현으로 대체하는 것
- 예외: 런타임/환경 제약으로 멀티에이전트 실행이 불가능한 경우에만, blocker와 필요한 입력/조치 사항을 즉시 보고

## Quick Start

1. Install globally:
```bash
./scripts/install_global.sh
```

2. Run setup on target repository (required before first `run/up`):
```bash
codex-teams setup --repo <repo>
```
`<repo>`는 `/mnt/<drive>/...`(예: `/mnt/c/...`) 경로여야 합니다.

3. Create team context (`TeamCreate` equivalent):
```bash
codex-teams teamcreate --session codex-fleet --workers 4 --description "Repo task force"
```

4. Run swarm:
```bash
codex-teams run --task "<user task>" --session codex-fleet --workers auto --tmux-layout split --dashboard
```
기본 모드(옵션 생략 시)는 `in-process-shared`입니다.

In-process backend example:
```bash
codex-teams run --task "<user task>" --session codex-fleet --teammate-mode in-process-shared --no-attach
```

Git binary override example (utility push/merge path):
```bash
codex-teams run --task "<user task>" --session codex-fleet --git-bin "/mnt/c/Program Files/Git/cmd/git.exe"
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

`codex-teams run/up` runtime:
- 백엔드: `tmux` | `in-process` | `in-process-shared`
- 기본 `--teammate-mode`: `in-process-shared` (옵션 미지정 시)
- `--teammate-mode`: `auto|tmux|in-process|in-process-shared`
- `auto` 선택 규칙:
  - non-interactive 실행: `in-process`
  - interactive + tmux 내부: `tmux`
  - interactive + tmux 외부: `in-process`
- 작업 디렉터리 규칙: `lead`는 루트 레포, `worker/utility`는 `.worktrees/<agent>`
- 기본 `--auto-delegate`: 초기 사용자 요청을 워커별 하위 태스크로 자동 분배
- `--no-auto-delegate`: 리더만 초기 지시를 받고 수동 분배
- `--workers auto`: 태스크 난이도에 따라 `worker pool`을 2~4 범위에서 자동 선택
- 워커 증설 원칙: 추가 워커가 필요하면 `--workers <N>`(또는 `auto`)로 재실행해 `.worktrees/worker-1..N`을 먼저 맞춘 뒤 작업을 분배
- 워커/유틸 처리 결과는 리더뿐 아니라 질문 보낸 동료에게도 자동 회신되어 지속 협업 루프를 유지
- 플랫폼 강제: Windows + WSL 환경에서만 실행 가능
- 레포 경로 강제: `/mnt/<drive>/...` Windows 마운트 경로만 허용

기본 역할 토폴로지:
- `lead` x 1 (오케스트레이션 전용, 실행 작업 금지)
- `worker` x N (가변)
- `utility` x 1
- 위 역할 형태는 고정 정책 (`lead + worker-N + utility-1`)

## Fixed Collaboration Workflow

`run/up` 실행 시 아래 협업 흐름을 기본 계약으로 사용:

1. scope: lead가 범위/리스크 정리
2. delegate: worker-N 분배
3. peer-qa: worker/utility/lead 간 질문/응답을 지속적으로 반복
4. on-demand-research: worker가 모르는 항목을 lead에 질문하면 lead가 리서치 후 `answer`/`task`로 재전달
5. review: lead가 결과 검수 후 승인/재작업 결정
6. handoff: utility-1로 인계 후 push/merge

세션 시작 시 버스에 `workflow-fixed ...` 상태 이벤트를 남겨 추적 가능.

tmux mode layout:
- tmux session `<session>`
- window `swarm`: `lead` + `worker-N` + `utility-1` split panes
- window `team-monitor`: full bus tail
- window `team-pulse`: pane activity heartbeat emitter
- window `team-mailbox`: unread mailbox를 각 pane으로 자동 주입
- optional window `team-dashboard` with `--dashboard`

in-process mode layout:
- no tmux session required
- each teammate (lead 포함) runs mailbox poll loop (`team_inprocess_agent.py`)
- optional shared supervisor mode (`team_inprocess_hub.py`)

This gives Claude Teams-style parallel visibility while keeping Codex CLI sessions native.

## TeamCreate/TeamDelete

- `teamcreate` creates/refreshes:
  - `.codex-teams/<session>/config.json` + `team.json`
  - `.codex-teams/<session>/inboxes/*.json`
  - `.codex-teams/<session>/control.json` (control request lifecycle)
  - `.codex-teams/<session>/state.json` + `runtime.json`
  - `.codex-teams/<session>/bus.sqlite`
  - room member registrations (`lead`, `worker-N`, `utility-1`, `system`, `monitor`, `orchestrator`)
- `teamdelete` removes the team folder (force mode kills active runtime agents and tmux session first).

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

- `scripts/team_codex.sh`: main entrypoint (`setup/run/up/status/merge/teamcreate/teamdelete/sendmessage`)
- `scripts/team_codex_ma.sh`: legacy codex-ma backend bridge
- `scripts/team_bus.py`: SQLite bus (`init`, `send`, `tail`, `status`, mailbox/control)
- `scripts/team_fs.py`: filesystem team config/mailbox/state/runtime core
- `scripts/team_mailbox.sh`: unread mailbox + pending control requests
- `scripts/team_control.sh`: plan/shutdown/permission request-response helper
- `scripts/team_dashboard.sh`: single-terminal live dashboard (all tmux panes)
- `scripts/team_pulse.sh`: automatic heartbeat from pane content changes
- `scripts/team_tmux_mailbox_bridge.py`: tmux pane mailbox auto-injector for continuous collaboration
- `scripts/team_inprocess_agent.py`: per-agent mailbox poll + codex exec loop
- `scripts/team_inprocess_hub.py`: shared in-process supervisor for multiple agents
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
