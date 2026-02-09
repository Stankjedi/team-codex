# team-codex

`codex-teams` 멀티 에이전트 스킬 저장소입니다.
현재 구조 기준으로 **tmux 단일 백엔드 + SQLite 버스 + 파일시스템 메일박스** 방식으로 동작합니다.

## 현재 구조

- `skills/codex-teams/SKILL.md`: 스킬 정의/운영 계약(소스 오브 트루스)
- `skills/codex-teams/scripts/team_codex.sh`: 메인 CLI 엔트리포인트
- `skills/codex-teams/scripts/team_bus.py`: SQLite 버스 처리
- `skills/codex-teams/scripts/team_fs.py`: 팀 상태/메일박스 파일 처리
- `skills/codex-teams/scripts/install_global.sh`: 전역 설치
- `TEAM-OPERATIONS.md`: 역할/운영 원칙

## 핵심 개념

### 역할 토폴로지

1. `lead` x 1 (오케스트레이션 전용)
2. `worker` x N (가변, `--workers auto` 시 2~4)
3. `utility` x 1 (push/merge 및 유틸 작업)

### 고정 협업 흐름

1. `scope`: lead가 범위/리스크 정리
2. `delegate`: worker 분배
3. `peer-qa`: lead/worker 질의응답 반복
4. `on-demand-research`: 필요 시 lead 재리서치
5. `review`: lead 검수/재작업 판단
6. `handoff`: utility 인계 및 git 처리

## 요구 사항

- `git`
- `python3` (권장 3.10+)
- `tmux`
- `codex` CLI
- (권장) `sqlite3`

필수 게이트:

```bash
export CODEX_EXPERIMENTAL_AGENT_TEAMS=1
export CODEX_TEAMS_GATE_TENGU_AMBER_FLINT=1
```

## 설치

저장소 루트에서 실행:

```bash
./skills/codex-teams/scripts/install_global.sh
```

개발 중 즉시 반영(심볼릭 링크) 설치:

```bash
./skills/codex-teams/scripts/install_global.sh --link
```

설치 확인:

```bash
export PATH="$HOME/.local/bin:$PATH"
codex-teams --help
```

## Quick Start

1) 대상 repo 준비 (최초 1회)

```bash
codex-teams setup --repo .
```

2) 팀 컨텍스트 생성

```bash
codex-teams teamcreate --session codex-fleet --workers 4 --description "Repo task force"
```

3) 멀티 에이전트 실행

```bash
codex-teams run --session codex-fleet --task "작업 내용" --workers auto --tmux-layout split --dashboard
```

4) 상태 확인

```bash
codex-teams status --session codex-fleet
```

5) 팀 메시지 전송

```bash
codex-teams sendmessage --session codex-fleet --type message --from lead --to worker-1 --content "해당 모듈 담당"
```

## 실행 모드

- 백엔드는 **tmux 단일 모드**만 지원
- `--teammate-mode auto|tmux`만 허용 (`auto`는 `tmux`로 정규화)
- 작업 디렉터리:
  - `lead`: 레포 루트
  - `worker/utility`: `.worktrees/<agent>`

예시:

```bash
codex-teams run --task "기능 고도화" --session codex-fleet --teammate-mode auto --workers auto
codex-teams run --task "핫픽스" --session codex-fleet --teammate-mode tmux --tmux-layout window
codex-teams run --task "수동 분배 테스트" --session codex-fleet --no-auto-delegate
```

## 자주 쓰는 명령

```bash
# setup
codex-teams setup --repo .

# run / up
codex-teams run --session codex-fleet --task "..." --workers auto --dashboard
codex-teams up --session codex-fleet --workers auto --dashboard

# team lifecycle
codex-teams teamcreate --session codex-fleet --workers 4 --description "..."
codex-teams teamdelete --session codex-fleet --force

# status / mailbox / dashboard
codex-teams status --session codex-fleet
codex-teams-dashboard --session codex-fleet --repo . --room main
tmux attach -t codex-fleet
```

## Git 바이너리 오버라이드 (WSL + Windows Git)

```bash
codex-teams run \
  --task "작업 내용" \
  --session codex-fleet \
  --git-bin "/mnt/c/Program Files/Git/cmd/git.exe"
```

또는 설정 파일(`.codex-multi-agent.config.sh`)에서:

```bash
GIT_BIN="/mnt/c/Program Files/Git/cmd/git.exe"
CODEX_TEAM_GIT_BIN="$GIT_BIN"
export PATH="/mnt/c/Program Files/Git/cmd:$PATH"
```

## 운영 팁 / 트러블슈팅

### 1) `run/up` 실행 전 Git 조건

- 대상 경로가 git repo여야 함
- 최소 1개 커밋이 있어야 함 (`HEAD` 필요)
- 오류 예: `fatal: Needed a single revision`
- 해결: `codex-teams setup --repo <repo>`

### 2) 워커가 자동 코딩을 안 하는 것처럼 보일 때

- `--no-auto-delegate`를 켜지 않았는지 확인
- 초기 `--task`가 실행 가능한 작업 단위인지 확인
- `codex-teams status --session <session>` 및 대시보드로 메시지/상태 확인

### 3) 워커 worktree에서 파일이 안 보일 때

- 원인: 루트의 **untracked 파일/폴더는 worker worktree에 자동 반영되지 않음**
- 해결:
  - 파일을 커밋해서 공통 기준점을 만든 뒤 실행
  - 또는 해당 파일을 워커가 접근 가능한 경로 기준으로 명시

## 스킬 호출 예시 (Codex)

```text
[$codex-teams](~/.codex/skills/codex-teams/SKILL.md) 사용해서 ...
```

## 라이선스

Apache License 2.0 (`LICENSE`)
