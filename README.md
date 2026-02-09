# codex-teams

`codex-teams`는 Codex 멀티 에이전트 스킬입니다.
이 저장소 버전은 **Windows + WSL 전용**이고, 기본적으로 아래 형태로 동작합니다.

- 리더: 현재 Codex IDE 채팅 세션(외부 리더)
- 워커: `worker-1`, `worker-2`, `worker-3` (고정 3명)
- 기본 모드: `in-process-shared` (리소스 절약형)
- 독립 실행: `codex-ma` 없이 `codex-teams`만으로 동작

## 1. 준비물

필수:

- `git`
- `python3` (권장 3.10+)
- `codex` CLI
- `wslpath` (WSL 기본 포함)

선택:

- `tmux` (`--teammate-mode tmux`를 쓸 때)
- `sqlite3` (상태 확인에 유용)

실행 전 게이트(필수):

```bash
export CODEX_EXPERIMENTAL_AGENT_TEAMS=1
export CODEX_TEAMS_GATE_TENGU_AMBER_FLINT=1
```

## 2. 설치

저장소 루트에서:

```bash
./skills/codex-teams/scripts/install_global.sh
```

개발 중 즉시 반영(심볼릭 링크 설치):

```bash
./skills/codex-teams/scripts/install_global.sh --link
```

PATH 설정 후 확인:

```bash
export PATH="$HOME/.local/bin:$PATH"
codex-teams --help
```

필요할 때만 의존성 자동 설치:

```bash
codex-teams deps --install
```
위 명령은 누락된 기본 의존성(`git`, `python3`, `wslpath`, `sqlite3`, `tmux`) 설치를 시도합니다.
(`codex` CLI는 수동 설치 대상)

## 3. 5분 시작 (가장 쉬운 방법)

예시 repo: `/mnt/c/Users/<you>/project`

1) 초기화(최초 1회)

```bash
codex-teams setup --repo /mnt/c/Users/<you>/project
```

2) 바로 실행

```bash
codex-teams run \
  --repo /mnt/c/Users/<you>/project \
  --session codex-fleet \
  --task "원하는 작업 설명"
```

3) 상태 확인

```bash
codex-teams status --repo /mnt/c/Users/<you>/project --session codex-fleet
```

중지/정리:

```bash
codex-teams teamdelete --repo /mnt/c/Users/<you>/project --session codex-fleet --force
```

## 4. 자주 쓰는 명령

- 실행(작업 포함):

```bash
codex-teams run --repo <repo> --session <session> --task "..."
```

- 실행(작업 없이 세션만):

```bash
codex-teams up --repo <repo> --session <session>
```

- 상태 확인:

```bash
codex-teams status --repo <repo> --session <session>
```

- 의존성 확인/자동 설치(필요할 때만):

```bash
codex-teams deps
codex-teams deps --install
```

- 워커 브랜치 통합(`ma/worker-1..3` -> 현재 브랜치):

```bash
codex-teams merge --repo <repo>
```

- 메시지 보내기:

```bash
codex-teams sendmessage --repo <repo> --session <session> \
  --type message --from lead --to worker-1 --content "이 작업 맡아줘"
```

## 5. 모드 선택 가이드

- `in-process-shared` (기본, 권장):
  리소스 사용량이 가장 안정적이라 일반적으로 이 모드를 추천합니다.
- `in-process`:
  워커별 개별 프로세스.
- `tmux`:
  화면으로 워커를 직접 보며 운영할 때 사용.

예시:

```bash
codex-teams run --repo <repo> --session <session> --task "..." --teammate-mode in-process-shared
codex-teams run --repo <repo> --session <session> --task "..." --teammate-mode tmux --tmux-layout split --dashboard
```

## 6. 설정 파일 (`.codex-multi-agent.config.sh`)

`setup`를 실행하면 자동 생성됩니다.
수동 생성이 필요하면:

```bash
codex-teams init --repo <repo>
```

자주 바꾸는 설정만 먼저 보면 됩니다:

```bash
# 워커 수는 고정 3 (다른 값 불가)
COUNT=3

# 기본 실행 모드 (권장)
TEAMMATE_MODE="in-process-shared"

# tmux 모드 설정
TMUX_LAYOUT="split"
ENABLE_TMUX_PULSE="false"
TMUX_MAILBOX_POLL_MS="1500"

# in-process 설정
INPROCESS_POLL_MS="1000"
INPROCESS_IDLE_MS="12000"
INPROCESS_SHARED_STABILIZE_SEC="12"
INPROCESS_SHARED_START_RETRIES="1"

# 세션/레포 동시 실행 잠금 대기 시간
SESSION_LOCK_WAIT_SEC="20"

# 통합 전략: merge | cherry-pick
MERGE_STRATEGY="merge"

# git 바이너리 (기본 권장)
GIT_BIN="git"
CODEX_TEAM_GIT_BIN="$GIT_BIN"
```

중요 포인트:

- `--workers`는 `3`만 허용됩니다.
- 기본 리더는 현재 Codex 세션(외부 리더)입니다.
- `TEAMMATE_MODE`를 바꾸지 않으면 기본값 `in-process-shared`로 실행됩니다.

## 7. 결과 파일 위치

실행 후 repo에 아래가 생성됩니다.

- `.worktrees/worker-1`, `.worktrees/worker-2`, `.worktrees/worker-3`
- `.codex-teams/<session>/bus.sqlite`
- `.codex-teams/<session>/inboxes/`
- `.codex-teams/<session>/logs/`
- `.codex-teams/<session>/runtime.json`
- `.codex-teams/<session>/state.json`

## 8. 자주 생기는 문제

- `not a git repository` 에러:

```bash
codex-teams setup --repo <repo>
```

- WSL 경로 에러:
  `--repo`는 `/mnt/c/...` 형식을 권장합니다. (`C:\...`도 자동 변환은 지원)

- `codex-teams: command not found`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

- CPU/RAM 사용량이 높을 때:
  `in-process-shared` 유지 + 아래 기본값 권장

```bash
TEAMMATE_MODE="in-process-shared"
ENABLE_TMUX_PULSE="false"
TMUX_MAILBOX_POLL_MS="1500"
INPROCESS_POLL_MS="1000"
```

- in-process-shared 허브가 바로 종료될 때:
  `status`와 허브 로그를 먼저 확인하세요.
  ```bash
  codex-teams status --repo <repo> --session <session>
  tail -n 80 <repo>/.codex-teams/<session>/logs/inprocess-hub.log
  tail -n 80 <repo>/.codex-teams/<session>/logs/inprocess-hub.lifecycle.log
  ```

- 같은 `<session>`에 대해 `up/run/teamdelete --force`를 병렬로 여러 터미널에서 동시에 실행하지 마세요.
  최신 버전은 세션 잠금을 사용하지만, 의도치 않은 강제 종료 가능성을 줄이려면 직렬 실행이 안전합니다.

- 이미 실행 중인 in-process 세션에서 다시 `up/run`을 호출하면 차단됩니다.
  중복 허브/워커를 띄우지 않기 위한 보호 동작입니다.

- 자동 설치가 실패할 때:
  패키지 매니저 권한 문제일 수 있습니다. `sudo` 권한을 확인하거나 직접 설치 후 다시 `codex-teams deps --install`을 실행하세요.

## 9. 한 줄 예시 (Codex에서 스킬 호출)

```text
[$codex-teams](~/.codex/skills/codex-teams/SKILL.md) 사용해서 <원하는 작업>
```
