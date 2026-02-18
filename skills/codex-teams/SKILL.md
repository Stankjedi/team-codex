---
name: codex-teams
description: Launch and operate Codex multi-agent sessions with real-time inter-agent messaging over a shared local bus. Use when tasks need lead-driven orchestration with reviewer + fixed workers.
---

# Codex Teams

Windows host + WSL 전용.
Codex CLI + in-process-shared + SQLite bus + filesystem mailbox 기반 멀티 에이전트 스킬.

## Mandatory Collaboration Policy

`$codex-teams` 스킬이 호출되면 작업은 **반드시 멀티에이전트 협업 방식**으로 수행해야 한다.

- 기본 실행 형태: `lead(external) + reviewer-1 + worker-1 + worker-2 + worker-3` 협업 토폴로지
- 유일 백엔드: `in-process-shared` (`auto`는 호환 별칭)
- 독립 실행: `codex-teams` 단독 스크립트로 동작
- 금지: 스킬 호출 후 단일 에이전트 단독 구현으로 대체하는 것
- 예외: 런타임/환경 제약으로 멀티에이전트 실행이 불가능한 경우에만, blocker와 필요한 입력/조치 사항을 즉시 보고

## Quick Start

1. Install globally:
```bash
./scripts/install_global.sh
```

2. Enable feature gates (required):
```bash
export CODEX_EXPERIMENTAL_AGENT_TEAMS=1
export CODEX_TEAMS_GATE_TENGU_AMBER_FLINT=1
```

3. Run setup on target repository (required before first `run/up`):
```bash
codex-teams setup --repo <repo>
```
`<repo>`는 `/mnt/<drive>/...`(예: `/mnt/c/...`) 경로여야 합니다.
필요하면 먼저 의존성 자동 설치를 실행하세요:
```bash
codex-teams deps --install
```

4. (Optional) Create team context explicitly (`TeamCreate` equivalent):
```bash
codex-teams teamcreate --session codex-fleet --workers 3 --description "Repo task force"
```
`run/up`은 내부적으로 TeamCreate refresh를 자동 수행하므로, 이 단계는 사전 확인/메타데이터 선설정용입니다.

5. Run swarm:
```bash
codex-teams run --task "<user task>" --session codex-fleet --teammate-mode in-process-shared
```

Git default is WSL `git` (recommended to reduce `conhost.exe` overhead). Optional Windows Git override:
```bash
codex-teams run --task "<user task>" --session codex-fleet --git-bin "/mnt/c/Program Files/Git/cmd/git.exe"
```
`--repo`, `--config`, `--git-bin`는 `C:\...` 입력도 자동으로 WSL 경로로 정규화합니다.

6. Monitor bus directly:
```bash
TEAM_DB=.codex-teams/codex-fleet/bus.sqlite ./scripts/team_tail.sh --all monitor
```

7. Open unified terminal dashboard:
```bash
codex-teams-dashboard --session codex-fleet --repo <repo> --room main
```

8. Send team message (`SendMessage` equivalent):
```bash
codex-teams sendmessage --session codex-fleet --type message --from lead --to worker-1 --content "Own reconnect logic"
```

## Runtime Layout

`codex-teams run/up` runtime:
- 백엔드: `in-process-shared` 단일 지원
- `--teammate-mode`: `in-process-shared` (또는 `auto` 별칭)
- 작업 디렉터리 규칙: `lead`/`reviewer`는 현재 Codex 세션의 repo root, `worker`는 `.worktrees/<agent>`
- 기본 `--auto-delegate`: 초기 사용자 요청을 워커별 하위 태스크로 자동 분배
- `--no-auto-delegate`: 리더만 초기 지시를 받고 수동 분배
- 고정 worker pool: 3 (`worker-1`, `worker-2`, `worker-3`) + reviewer-1(review-only)
- `--workers`는 `3`만 허용
- 워커 처리 결과는 리더뿐 아니라 질문 보낸 동료에게도 자동 회신되어 지속 협업 루프를 유지
- 플랫폼 강제: Windows + WSL 환경에서만 실행 가능
- 레포 경로 강제: `/mnt/<drive>/...` Windows 마운트 경로만 허용

기본 역할 토폴로지:
- `lead` x 1 (오케스트레이션 전용, 외부 세션)
- `reviewer` x 1 (리뷰 전용, 코드 수정 금지)
- `worker` x 3 (고정)
- 위 역할 형태는 고정 정책 (`lead(external) + reviewer-1 + worker-1 + worker-2 + worker-3`)

## Fixed Collaboration Workflow

`run/up` 실행 시 아래 협업 흐름을 기본 계약으로 사용:

1. scope: lead가 범위/리스크 정리
2. delegate: worker-1/2/3 분배
3. peer-qa: worker/lead 간 질문/응답을 지속적으로 반복
4. peer-sync: worker 완료/중간 산출물은 관련 worker들에게 `peer-sync` 업데이트로 공유
5. on-demand-research: worker가 모르는 항목을 lead에 질문하면 lead가 리서치 후 `answer`/`task`로 재전달
6. dual-review: worker 완료 후 lead/reviewer가 독립 리뷰 수행
7. compare+redelegate: lead가 두 리뷰를 대조하고 이슈가 있으면 worker에 재위임
8. handoff: 이슈가 없으면 지정 worker로 인계 후 push/merge

세션 시작 시 버스에 `workflow-fixed ...` 상태 이벤트를 남겨 추적 가능.

Performance defaults:
- generated config keeps `TEAMMATE_MODE="in-process-shared"`
- in-process poll default: `INPROCESS_POLL_MS=250`
- in-process-shared startup stabilize: `INPROCESS_SHARED_STABILIZE_SEC=12`
- in-process-shared startup retries: `INPROCESS_SHARED_START_RETRIES=1`
- session/repo lock wait: `SESSION_LOCK_WAIT_SEC=20`

in-process-shared runtime layout:
- no tmux session required
- shared supervisor (`team_inprocess_hub.py`)가 reviewer-1 + worker-1/2/3 실행을 통합 관리
- lead review-ready 판단은 워커의 텍스트 done 키워드가 아니라 shared hub의 구조화 상태(성공 실행 + pending queue 없음)로 계산
- shared mode 진단 파일:
  - `<repo>/.codex-teams/<session>/logs/inprocess-hub.log`
  - `<repo>/.codex-teams/<session>/logs/inprocess-hub.lifecycle.log`
  - `<repo>/.codex-teams/<session>/logs/inprocess-hub.heartbeat.json`
- 동일 session에서 in-process-shared 런타임이 이미 살아있으면 `run/up`은 중복 기동을 차단

This gives Claude Teams-style parallel visibility while keeping Codex CLI sessions native.

## TeamCreate/TeamDelete

- `teamcreate` creates/refreshes:
  - `.codex-teams/<session>/config.json` + `team.json`
  - `.codex-teams/<session>/inboxes/*.json`
  - `.codex-teams/<session>/control.json` (control request lifecycle)
  - `.codex-teams/<session>/state.json` + `runtime.json`
  - `.codex-teams/<session>/bus.sqlite`
  - room member registrations (`lead`, `reviewer-1`, `worker-1`, `worker-2`, `worker-3`, `system`, `monitor`, `orchestrator`)
- `teamdelete` removes the team folder (force mode kills active runtime agents first).

## Message Contract

Roles:
- `lead`, `reviewer-1`, `worker-1`, `worker-2`, `worker-3`, `monitor`, `system`, `orchestrator`

Kinds:
- `task`, `question`, `answer`, `status`, `blocker`, `system`
- `message`, `broadcast`
- `plan_approval_request/response`, `shutdown_request/response`, `permission_request/response`
- `shutdown_approved`, `shutdown_rejected`, `mode_set_request/response`

Control request types are tracked in both SQLite and filesystem (`control.json`) with shared `request_id`.
Runtime control handling uses filesystem `control.json` as primary authority; SQLite is mirrored when available.

Full protocol: `references/protocol.md`

## Model Selection

Model precedence (highest first):
1. CLI override (`--model`, `--director-model`, `--worker-model`, `--reviewer-model`)
2. Project/user `.codex/config.toml` via `resolve_model.py` (`lead/worker/reviewer` role keys 지원)
3. Codex profile defaults

## Scripts

- `scripts/team_codex.sh`: main entrypoint (`setup/run/up/status/merge/teamcreate/teamdelete/sendmessage`)
- `scripts/team_bus.py`: SQLite bus (`init`, `send`, `tail`, `status`, mailbox/control)
- `scripts/team_fs.py`: filesystem team config/mailbox/state/runtime core
- `scripts/team_mailbox.sh`: unread mailbox + pending control requests
- `scripts/team_control.sh`: plan/shutdown/permission request-response helper
- `scripts/team_inprocess_hub.py`: shared in-process supervisor for multiple agents
- `scripts/install_global.sh`: global install + launchers

## IDE / Terminal Usage

Dashboard extension is removed. Use terminal-first monitoring instead.

- Or open unified dashboard:
```bash
codex-teams-dashboard --session <session> --repo <repo> --room main
```
