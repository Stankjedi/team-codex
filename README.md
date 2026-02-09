# team-codex

Codex 멀티 에이전트 협업 스킬(`codex-teams`) 저장소입니다.

## 구성

- `skills/codex-teams`: 팀 생성/삭제, 메시징, tmux/in-process 실행 백엔드
- `doc/codex-teams-*-validation-2026-02-09.md`: 실시간 협업 검증 리포트 모음

## 테스트 프로젝트 상태

- 기존 샌드박스 테스트 프로젝트(`windows-calculator`, `windows-unit-converter`)는 정리되어 현재 저장소에는 포함되어 있지 않습니다.

## 실행 방식

`codex-teams`는 **Codex CLI 대화창 내부 명령이 아니라 셸 명령**입니다.

```bash
codex-teams <command> [options]
```

## 설치

```bash
./skills/codex-teams/scripts/install_global.sh
```

## 스킬 빠른 등록 가이드

현재 프로젝트를 Codex 스킬로 바로 등록하려면 아래 순서로 진행하면 됩니다.

1. 개발용(권장, 즉시 반영) 등록
```bash
cd /path/to/team-codex
./skills/codex-teams/scripts/install_global.sh --link
```

2. 배포용(복사본) 등록
```bash
cd /path/to/team-codex
./skills/codex-teams/scripts/install_global.sh
```

3. PATH 확인 (`codex-teams` 명령 인식)
```bash
export PATH="$HOME/.local/bin:$PATH"
codex-teams --help
```

4. 등록 위치 확인
- 기본 설치 경로: `~/.codex/skills/codex-teams`
- 런처 경로: `~/.local/bin/codex-teams`

5. Codex에서 스킬 명시 호출 예시
```text
[$codex-teams](~/.codex/skills/codex-teams/SKILL.md) 사용해서 ...
```

업데이트 반영 규칙:
- `--link` 설치: 저장소 파일 수정 즉시 반영
- 복사 설치: 저장소 업데이트 후 설치 스크립트를 다시 실행해야 반영

## 의존성

- 필수
  - `git`
  - `python3` (권장 3.10+)
  - `codex` CLI (`codex-teams`가 내부적으로 호출)
- 권장
  - `sqlite3` (버스/메일박스 검증에 유용)
- 선택
  - `tmux` (`--teammate-mode tmux` 사용 시 필요)

기본 게이트(활성):

```bash
export CODEX_EXPERIMENTAL_AGENT_TEAMS=1
export CODEX_TEAMS_GATE_TENGU_AMBER_FLINT=1
```

## 핵심 기능

### 1) TeamCreate / TeamDelete

```bash
codex-teams teamcreate --session codex-fleet --workers 4 --description "기능 개발 팀"
codex-teams teamdelete --session codex-fleet --force
```

생성 아티팩트:
- `.codex-teams/<session>/config.json`
- `.codex-teams/<session>/team.json` (호환용)
- `.codex-teams/<session>/inboxes/*.json`
- `.codex-teams/<session>/control.json` (plan/shutdown/permission/mode_set 요청 상태)
- `.codex-teams/<session>/state.json`
- `.codex-teams/<session>/runtime.json`
- `.codex-teams/<session>/bus.sqlite`

### 2) 실행 백엔드

```bash
codex-teams run --session codex-fleet --task "작업 내용" --teammate-mode auto --workers auto
codex-teams run --session codex-fleet --task "작업 내용" --teammate-mode tmux --tmux-layout split --dashboard
codex-teams run --session codex-fleet --task "작업 내용" --teammate-mode tmux --tmux-layout window
codex-teams run --session codex-fleet --task "작업 내용" --teammate-mode in-process --no-attach
codex-teams run --session codex-fleet --task "작업 내용" --teammate-mode in-process-shared --no-attach
codex-teams run --session codex-fleet --task "작업 내용" --no-auto-delegate
```

- `auto`: 대화형 터미널 + `tmux` 사용 가능 시 `tmux`, 그 외에는 `in-process-shared` 선택
- `tmux`: 같은 TUI에서 `director + pair-N` 분할/창 실행
- `in-process`: 파일 메일박스 폴링 루프 기반 워커 프로세스 실행
- `in-process-shared`: 단일 허브 프로세스에서 다수 워커 루프를 공유 실행
- `--workers auto`: 작업 난이도 기준으로 `pair`를 **2~4명 범위에서 능동적으로 스폰**
- 기본값으로 초기 태스크를 워커별 하위 태스크로 자동 분할(`--auto-delegate`), 필요 시 `--no-auto-delegate`로 비활성화

### 2-1) 실시간 협업 확정 흐름

`codex-teams run`은 아래 흐름을 기본 계약으로 사용합니다.

1. `scope`: director가 작업 범위와 우선순위를 명시
2. `delegate`: pair-N에게 역할 분배
3. `peer-qa`: pair 간 `question/answer`를 필요 시마다 반복 교환
4. `verify`: 테스트/컴파일/검증 커맨드 증거 공유
5. `handoff`: done 메시지에 변경 파일, 검증 결과, 잔여 리스크 포함

세션 시작 시 버스(`bus.sqlite`)에 `workflow-fixed ...` 상태 메시지가 기록됩니다.

### 3) SendMessage 스키마

```bash
codex-teams sendmessage --session codex-fleet --type message --from director --to pair-1 --content "auth 담당"
codex-teams sendmessage --session codex-fleet --type broadcast --from director --content "10분 뒤 점검"
codex-teams sendmessage --session codex-fleet --type shutdown_request --from director --to pair-1 --content "중단"
codex-teams sendmessage --session codex-fleet --type plan_approval_request --from pair-1 --to director --content "계획 승인 요청"
codex-teams sendmessage --session codex-fleet --type permission_response --from director --to pair-1 --request-id <id> --approve --content "허용"
codex-teams sendmessage --session codex-fleet --type mode_set_request --from director --to pair-1 --content "delegate"
```

지원 타입:
- `message`, `broadcast`
- `shutdown_request`, `shutdown_response`, `shutdown_approved`, `shutdown_rejected`
- `plan_approval_request`, `plan_approval_response`
- `permission_request`, `permission_response`
- `mode_set_request`, `mode_set_response`

### 4) 상태/메일박스/제어

```bash
codex-teams status --session codex-fleet
codex-teams-mailbox --repo . --session codex-fleet --mode fs inbox director --unread --json
codex-teams-mailbox --repo . --session codex-fleet --mode fs pending director --json
codex-teams-control --repo . --session codex-fleet request --type plan_approval pair-1 director "Task 04 계획 승인 요청"
codex-teams-dashboard --session codex-fleet --repo . --room main
```

`sendmessage`의 `*_request/*_response`는 SQLite(`bus.sqlite`)와 파일 상태(`control.json`)를 함께 갱신해 request_id 기준으로 추적됩니다.

## IDE/터미널 연동

- 대시보드 확장은 제거된 상태이며, 기본 운영은 터미널 기반입니다.
- IDE 통합 터미널에서 아래 명령으로 모니터링합니다.
  - `tmux attach -t <session>`
  - `codex-teams-dashboard --session <session> --repo . --room main`
- in-process 계열 모드에서는 로그를 직접 확인합니다.
  - `.codex-teams/<session>/logs/inprocess-hub.log`
  - `.codex-teams/<session>/logs/<pair>.log`

## 라이선스

Apache License 2.0 (`LICENSE`)
