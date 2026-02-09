# team-codex

Codex 멀티 에이전트 협업을 위한 스킬(`codex-teams`)과 IDE 대시보드 확장 모음입니다.

## 구성

- `skills/codex-teams`: Codex CLI + tmux 기반 팀 실행 스킬
- `extensions/antigravity-codex-teams-viewer`: IDE 내 실시간 팀 대시보드 확장

## 빠른 사용법

### 1) 전역 설치

```bash
./skills/codex-teams/scripts/install_global.sh
```

### 2) 팀 컨텍스트 생성 (`TeamCreate`)

```bash
codex-teams teamcreate --session codex-fleet --workers 4 --description "기능 개발 팀"
```

생성 위치:
- 팀 설정: `.codex-teams/<session>/team.json`
- 버스 DB: `.codex-teams/<session>/bus.sqlite`

### 3) Codex CLI 기반 스웜 실행

```bash
codex-teams run --task "원하는 작업" --session codex-fleet --dashboard
```

기본 동작:
- tmux `swarm` 창에 `director + pair-N` 패널을 한 화면에 분할 실행
- `team-monitor` 창에서 팀 버스 메시지 tail
- `team-pulse` 창에서 워커 heartbeat 자동 발행
- 옵션 `--workers` 미지정 시 작업 난이도에 따라 2~4 자동 선택

### 4) 팀 메시지 전송 (`SendMessage`)

```bash
codex-teams sendmessage --session codex-fleet --type message --from director --to pair-1 --content "auth 모듈 담당"
codex-teams sendmessage --session codex-fleet --type broadcast --from director --content "중간 점검 10분 후"
```

지원 타입:
- `message`, `broadcast`
- `shutdown_request`, `shutdown_response`
- `plan_approval_response`
- `permission_request`, `permission_response`

### 5) 상태/메일박스/제어 확인

```bash
codex-teams status --session codex-fleet
TEAM_DB=.codex-teams/codex-fleet/bus.sqlite codex-teams-mailbox --room main inbox director --unread
TEAM_DB=.codex-teams/codex-fleet/bus.sqlite codex-teams-control --room main request --type plan_approval pair-1 director "Task 04 계획 승인 요청"
```

## IDE 스킬 사용

채팅 입력창에서 `$` 입력 후 `Codex Teams`를 선택하면 됩니다.

예시:

```text
$codex-teams 이 레포에서 버그 원인 분석하고 워커 3개로 병렬 수정해줘
```

## 레거시 백엔드

기존 `codex-ma` 방식이 필요하면 아래 별도 런처를 사용하세요.

```bash
codex-teams-ma run --task "원하는 작업"
```

## 라이선스

Apache License 2.0 (`LICENSE`).
