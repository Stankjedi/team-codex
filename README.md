# team-codex

`codex-teams` 멀티 에이전트 스킬 저장소입니다.
현재 구현은 **Windows host + WSL 전용**이며, **tmux / in-process 백엔드 + SQLite 버스 + 파일시스템 메일박스**로 동작합니다.

## 1) 지원 범위 요약

- 플랫폼: Windows + WSL (권장 WSL2)
- 저장소 경로: `/mnt/<drive>/...` (예: `/mnt/c/...`)
- 팀 토폴로지: `lead x1 + worker xN + utility x1` (고정 정책)
- Git 기본값: WSL `git` (Windows `git.exe`는 옵트인)
- 경로 자동 변환: `--repo`, `--config`, `--git-bin`에 `C:\...` 입력 가능

## 2) 디렉터리 구조

- `skills/codex-teams/SKILL.md`: 스킬 정의/운영 계약(소스 오브 트루스)
- `skills/codex-teams/scripts/team_codex.sh`: 메인 CLI
- `skills/codex-teams/scripts/team_bus.py`: SQLite 메시지 버스
- `skills/codex-teams/scripts/team_fs.py`: 팀 상태/메일박스 파일 관리
- `skills/codex-teams/scripts/team_inprocess_agent.py`: 인프로세스 에이전트 루프
- `skills/codex-teams/scripts/team_inprocess_hub.py`: 인프로세스 공유 허브
- `skills/codex-teams/scripts/team_tmux_mailbox_bridge.py`: tmux 메일박스 브리지
- `skills/codex-teams/scripts/install_global.sh`: 글로벌 설치 스크립트
- `TEAM-OPERATIONS.md`: 역할/운영 원칙

## 3) 요구 사항

- `git`
- `python3` (권장 3.10+)
- `codex` CLI
- `wslpath` (WSL 기본 유틸)
- `tmux` (tmux 백엔드 사용 시)
- `sqlite3` (권장)

필수 게이트:

```bash
export CODEX_EXPERIMENTAL_AGENT_TEAMS=1
export CODEX_TEAMS_GATE_TENGU_AMBER_FLINT=1
```

## 4) 설치

저장소 루트에서 실행:

```bash
./skills/codex-teams/scripts/install_global.sh
```

개발 중 즉시 반영(심볼릭 링크):

```bash
./skills/codex-teams/scripts/install_global.sh --link
```

확인:

```bash
export PATH="$HOME/.local/bin:$PATH"
codex-teams --help
```

## 5) Quick Start

1. 대상 저장소 초기화 (최초 1회)

```bash
codex-teams setup --repo /mnt/c/Users/<you>/project
```

2. 팀 컨텍스트 생성

```bash
codex-teams teamcreate --repo /mnt/c/Users/<you>/project --session codex-fleet --workers 2 --description "Repo task force"
```

3. 실행

```bash
codex-teams run --repo /mnt/c/Users/<you>/project --session codex-fleet --task "작업 내용" --dashboard
```

4. 상태 확인

```bash
codex-teams status --repo /mnt/c/Users/<you>/project --session codex-fleet
```

5. 메시지 전송

```bash
codex-teams sendmessage --repo /mnt/c/Users/<you>/project --session codex-fleet --type message --from lead --to worker-1 --content "해당 모듈 담당"
```

## 6) 작업 결과가 생성되는 위치

| 위치 | 설명 |
|---|---|
| `.worktrees/lead-1` | lead 작업 워크트리 (기본값) |
| `.worktrees/worker-<n>` | worker 작업 워크트리 |
| `.worktrees/utility-1` | utility 작업 워크트리 |
| `.codex-teams/<session>/bus.sqlite` | 팀 메시지 버스 DB |
| `.codex-teams/<session>/inboxes/` | 에이전트 메일박스 |
| `.codex-teams/<session>/logs/` | 런타임 로그 |
| `.codex-teams/<session>/runtime.json` | 런타임 상태 |
| `.codex-teams/<session>/state.json` | 팀 상태 스냅샷 |
| `.codex-teams/.viewer-session.json` | 대시보드/뷰어 브리지 정보 |
| `ma/<agent>` 브랜치 | worktree별 작업 브랜치 |

## 7) 실행 모드

- 백엔드: `tmux | in-process | in-process-shared`
- 기본 엔진 값: `in-process-shared`
- 실사용 기본값: `setup`이 생성한 `.codex-multi-agent.config.sh`에서 `TEAMMATE_MODE="tmux"`
- `--teammate-mode auto` 해석:
  - non-interactive: `in-process`
  - interactive + tmux 내부: `tmux`
  - interactive + tmux 외부: `in-process`
- 작업 디렉터리:
  - lead: `.worktrees/lead-1` (기본)
  - worker/utility: `.worktrees/<agent>`

예시:

```bash
codex-teams run --repo /mnt/c/Users/<you>/project --session codex-fleet --task "대규모 작업" --workers auto
codex-teams run --repo /mnt/c/Users/<you>/project --session codex-fleet --task "백그라운드" --teammate-mode in-process --no-attach
codex-teams run --repo /mnt/c/Users/<you>/project --session codex-fleet --task "tmux split" --teammate-mode tmux --tmux-layout split --dashboard
codex-teams run --repo /mnt/c/Users/<you>/project --session codex-fleet --task "수동 분배" --no-auto-delegate
```

## 8) 명령어 상세

### `setup`

저장소를 codex-teams 실행 가능한 상태로 준비합니다.

```bash
codex-teams setup --repo /mnt/c/Users/<you>/project
```

- git 저장소가 아니면 초기화
- 최소 1개 커밋 생성
- 기본 설정 파일 `.codex-multi-agent.config.sh` 자동 생성

### `run` / `up`

- `run`: 팀 실행 + 초기 task 주입 (`--task` 필수)
- `up`: 팀만 실행 (task 주입 없음)

주요 옵션:

- `--workers N|auto`: 워커 수 지정 (`auto`는 task 난이도 기반 2~4)
- `--teammate-mode auto|tmux|in-process|in-process-shared`
- `--tmux-layout split|window`
- `--dashboard`, `--dashboard-window`, `--dashboard-lines`, `--dashboard-messages`
- `--auto-delegate` / `--no-auto-delegate`
- `--no-attach`

### `status`

런타임/상태/버스/tmux 상태를 확인합니다.

```bash
codex-teams status --repo /mnt/c/Users/<you>/project --session codex-fleet
```

### `teamcreate` / `teamdelete`

팀 컨텍스트를 명시적으로 생성/삭제합니다.

```bash
codex-teams teamcreate --repo /mnt/c/Users/<you>/project --session codex-fleet --workers 2 --description "..."
codex-teams teamdelete --repo /mnt/c/Users/<you>/project --session codex-fleet --force
```

### `sendmessage`

에이전트 간 메시지/제어 메시지를 전송합니다.

```bash
codex-teams sendmessage --repo /mnt/c/Users/<you>/project --session codex-fleet --type message --from lead --to worker-1 --content "담당 영역 업데이트"
```

`--type` 지원 값:

- `message`, `broadcast`
- `shutdown_request`, `shutdown_response`, `shutdown_approved`, `shutdown_rejected`
- `plan_approval_request`, `plan_approval_response`
- `permission_request`, `permission_response`
- `mode_set_request`, `mode_set_response`

### `merge`

레거시 codex-ma 백엔드 merge 경로를 사용합니다.

```bash
codex-teams merge --repo /mnt/c/Users/<you>/project
```

## 9) 설정 파일 (`.codex-multi-agent.config.sh`) 상세

`setup` 시 자동 생성되며, 필요 시 직접 편집합니다.

```bash
cp .codex-multi-agent.config.example.sh .codex-multi-agent.config.sh
```

주요 변수:

| 변수 | 기본값 | 설명 |
|---|---|---|
| `COUNT` | `2` | 기본 워커 수 |
| `PREFIX` | `worker` | 워커 이름 prefix |
| `WORKTREES_DIR` | `.worktrees` | worktree 루트 디렉터리 |
| `LEAD_WORKTREE_NAME` | `lead-1` | lead worktree 이름 |
| `BASE_REF` | `HEAD` | worktree 분기 기준 ref |
| `USE_BASE_WIP` | `false` | tracked 변경 snapshot 기반 사용 여부 |
| `ALLOW_DIRTY` | `true` | dirty tree 허용 여부 |
| `TMUX_SESSION` | `codex-fleet` | tmux 세션명 |
| `KILL_EXISTING_SESSION` | `false` | 기존 세션 강제 종료 여부 |
| `CODEX_BIN` | `codex` | Codex 실행 바이너리 |
| `DIRECTOR_PROFILE` | `director` | lead 기본 프로필 |
| `WORKER_PROFILE` | `pair` | worker/utility 기본 프로필 |
| `DIRECTOR_INPUT_DELAY` | `2` | run 시 lead 초기 입력 지연(초) |
| `MERGE_STRATEGY` | `merge` | 통합 전략 (`merge`/`cherry-pick`) |
| `TEAMMATE_MODE` | `tmux` (생성 config 기준) | 기본 백엔드 |
| `TMUX_LAYOUT` | `split` | tmux 레이아웃 |
| `PERMISSION_MODE` | `default` | Codex permission mode |
| `PLAN_MODE_REQUIRED` | `false` | plan mode 요구 여부 |
| `AUTO_DELEGATE` | `true` | 초기 task 자동 분배 여부 |
| `AUTO_KILL_DONE_WORKER_TMUX` | `true` | done 워커 pane/window 자동 정리 |
| `GIT_BIN` | `git` | git 실행 바이너리 |
| `CODEX_TEAM_GIT_BIN` | `$GIT_BIN` | 팀 런타임용 git 바이너리 |

값 우선순위(높음 -> 낮음):

1. CLI 옵션 (예: `--git-bin`, `--workers`, `--session`)
2. 환경/설정 변수 (`CODEX_*`, `.codex-multi-agent.config.sh`)
3. 스크립트 내부 기본값

## 10) Git/경로 정책

기본 권장:

```bash
GIT_BIN="git"
CODEX_TEAM_GIT_BIN="$GIT_BIN"
```

Windows Git이 필요한 경우(옵트인):

```bash
codex-teams run \
  --repo /mnt/c/Users/<you>/project \
  --session codex-fleet \
  --task "작업 내용" \
  --git-bin "/mnt/c/Program Files/Git/cmd/git.exe"
```

경로 자동 변환 예시:

```bash
codex-teams status --repo "C:\Users\<you>\project" --session codex-fleet
codex-teams status --repo "C:\Users\<you>\project" --config "C:\Users\<you>\project\.codex-multi-agent.config.sh"
codex-teams status --repo "C:\Users\<you>\project" --git-bin "C:\Program Files\Git\cmd\git.exe"
```

참고:

- Windows `git.exe`는 WSL에서 `conhost.exe` 부하가 생길 수 있어 기본값으로 권장하지 않습니다.
- WSL Git/Windows Git 혼용 시 credential helper, `core.autocrlf` 차이로 동작 차이가 날 수 있습니다.

## 11) 운영 팁 / 트러블슈팅

### `run/up` 전에 꼭 확인

- 대상 경로가 git repo인지 확인
- 최소 1개 커밋(`HEAD`)이 있는지 확인
- 실패 시:

```bash
codex-teams setup --repo /mnt/c/Users/<you>/project
```

### 워커가 일하지 않는 것처럼 보일 때

- `--no-auto-delegate` 사용 여부 확인
- `--task`를 실행 가능한 단위로 작성
- `codex-teams status --repo <repo> --session <session>` 확인
- tmux 모드에서는 `team-mailbox` 윈도우에서 메시지 주입이 진행되는지 확인

### worktree에서 파일이 안 보일 때

- 루트의 untracked 파일/폴더는 자동 반영되지 않을 수 있습니다.
- 필요한 파일은 커밋 후 실행하거나, 워커 기준 경로를 명시하세요.

## 12) 스킬 호출 예시 (Codex)

```text
[$codex-teams](~/.codex/skills/codex-teams/SKILL.md) 사용해서 ...
```
