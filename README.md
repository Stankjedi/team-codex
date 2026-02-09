# team-codex

`codex-teams` 멀티 에이전트 스킬 저장소입니다.
현재 구조 기준으로 **Windows host + WSL 전용**, 그리고 **tmux/in-process 백엔드 + SQLite 버스 + 파일시스템 메일박스** 방식으로 동작합니다.

## 현재 구조

- `skills/codex-teams/SKILL.md`: 스킬 정의/운영 계약(소스 오브 트루스)
- `skills/codex-teams/scripts/team_codex.sh`: 메인 CLI 엔트리포인트
- `skills/codex-teams/scripts/team_bus.py`: SQLite 버스 처리
- `skills/codex-teams/scripts/team_fs.py`: 팀 상태/메일박스 파일 처리
- `skills/codex-teams/scripts/team_inprocess_agent.py`: 인프로세스 워커 루프
- `skills/codex-teams/scripts/team_inprocess_hub.py`: 인프로세스 공유 허브
- `skills/codex-teams/scripts/install_global.sh`: 전역 설치
- `TEAM-OPERATIONS.md`: 역할/운영 원칙

## 핵심 개념

### 플랫폼 정책

1. 실행 환경은 Windows + WSL(권장: WSL2)만 지원
2. Linux/macOS 네이티브 실행은 지원하지 않음
3. Git은 WSL에서 Windows Git(`git.exe`) 우선 사용
4. 대상 repo는 `/mnt/<drive>/...` 경로에서만 지원

### 역할 토폴로지

1. `lead` x 1 (오케스트레이션 전용)
2. `worker` x N (가변, `--workers auto` 시 2~4)
3. `utility` x 1 (push/merge 및 유틸 작업)
4. 위 토폴로지는 고정 정책 (lead + worker-N + utility-1)

### 고정 협업 흐름

1. `scope`: lead가 범위/리스크 정리
2. `delegate`: worker 분배
3. `peer-qa`: worker/utility/lead 간 질의응답을 지속 루프로 반복
4. `on-demand-research`: worker가 모르는 항목을 `question`으로 올리면 lead가 리서치 후 `answer`/`task`로 재전달
5. `review`: lead 검수/재작업 판단
6. `handoff`: utility 인계 및 git 처리

## 요구 사항

- `git`
- `python3` (권장 3.10+)
- `tmux` (tmux 백엔드 사용 시)
- `codex` CLI
- (권장) `sqlite3`
- `wslpath` (WSL 기본 유틸)

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
`--repo` 경로는 `/mnt/c/...` 같은 Windows 마운트 경로여야 합니다.

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

- 백엔드: `tmux|in-process|in-process-shared`
- 기본 `--teammate-mode`: `in-process-shared` (옵션 미지정 시)
- `--teammate-mode auto|tmux|in-process|in-process-shared`
- `auto` 해석 규칙:
  - non-interactive 실행: `in-process`
  - interactive + tmux 내부: `tmux`
  - interactive + tmux 외부: `in-process`
- 작업 디렉터리:
  - `lead`: 레포 루트
  - `worker/utility`: `.worktrees/<agent>`
- tmux 백엔드: `team-mailbox` 윈도우에서 메일박스를 pane으로 자동 주입해 지속 협업 루프 유지
- in-process 계열: lead 에이전트도 함께 루프에 참여해 워커 질문에 자동으로 리서치/응답 가능

예시:

```bash
codex-teams run --task "기능 고도화" --session codex-fleet --workers auto
codex-teams run --task "기능 고도화" --session codex-fleet --teammate-mode in-process-shared --workers auto
codex-teams run --task "핫픽스" --session codex-fleet --teammate-mode tmux --tmux-layout window
codex-teams run --task "백그라운드 실행" --session codex-fleet --teammate-mode in-process --no-attach
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
- tmux 모드에서는 `team-mailbox` 윈도우가 떠서 메시지를 pane에 주입하는지 확인
- tmux pane 종료/쉘 종료 문제가 있으면 `--teammate-mode in-process`로 우회해 워커 루프를 유지

### 3) 워커 worktree에서 파일이 안 보일 때

- 원인: 루트의 **untracked 파일/폴더는 worker worktree에 자동 반영되지 않음**
- 해결:
  - 파일을 커밋해서 공통 기준점을 만든 뒤 실행
  - 또는 해당 파일을 워커가 접근 가능한 경로 기준으로 명시

## 스킬 호출 예시 (Codex)

```text
[$codex-teams](~/.codex/skills/codex-teams/SKILL.md) 사용해서 ...
```
