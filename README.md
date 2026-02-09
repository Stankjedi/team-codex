# team-codex

Codex 멀티 에이전트 협업 스킬(`codex-teams`)과 IDE 대시보드 확장 저장소입니다.

## 구성

- `skills/codex-teams`: 팀 생성/삭제, 메시징, tmux/in-process 실행 백엔드
- `extensions/antigravity-codex-teams-viewer`: IDE 웹뷰 대시보드
- `apps/sandbox/windows-calendar`: Windows용 Tkinter 달력 데모 앱(격리 샘플)

## 실행 방식

`codex-teams`는 **Codex CLI 대화창 내부 명령이 아니라 셸 명령**입니다.

```bash
codex-teams <command> [options]
```

## 설치

```bash
./skills/codex-teams/scripts/install_global.sh
```

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
codex-teams run --session codex-fleet --task "작업 내용" --teammate-mode auto
codex-teams run --session codex-fleet --task "작업 내용" --teammate-mode tmux --tmux-layout split --dashboard
codex-teams run --session codex-fleet --task "작업 내용" --teammate-mode tmux --tmux-layout window
codex-teams run --session codex-fleet --task "작업 내용" --teammate-mode in-process --no-attach
codex-teams run --session codex-fleet --task "작업 내용" --teammate-mode in-process-shared --no-attach
codex-teams run --session codex-fleet --task "작업 내용" --no-auto-delegate
```

- `auto`: 환경에 따라 `tmux` 또는 `in-process` 선택
- `tmux`: 같은 TUI에서 `director + pair-N` 분할/창 실행
- `in-process`: 파일 메일박스 폴링 루프 기반 워커 프로세스 실행
- `in-process-shared`: 단일 허브 프로세스에서 다수 워커 루프를 공유 실행
- 기본값으로 초기 태스크를 워커별 하위 태스크로 자동 분할(`--auto-delegate`), 필요 시 `--no-auto-delegate`로 비활성화

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

## IDE 확장 연동

- `$` 입력 후 `Codex Teams` 스킬을 선택해 사용 가능
- `codex-teams run/up/teamcreate` 실행 시 `.codex-teams/.viewer-session.json` 브리지 파일이 자동 갱신됨
- 확장은 브리지 파일을 감지해 현재 session/room/repo를 자동 추적
- 확장은 통합 터미널을 새로 열지 않고 `codex-teams-dashboard --once` 결과만 웹뷰에 렌더링
- tmux가 없을 때도 `runtime.json` + `logs/<agent>.log` 기반으로 in-process 워커 섹션 표시
- Windows 경로(`C:\...`)를 설정한 경우에도 WSL 경로로 자동 변환해 실행
- Windows에서 특정 WSL 배포판을 쓰려면 `agCodexTeamsViewer.wslDistro` 설정

## 라이선스

Apache License 2.0 (`LICENSE`)
