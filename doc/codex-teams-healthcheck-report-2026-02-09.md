# Codex Teams 스킬 동작 검증 보고서

- 점검일: 2026-02-09
- 점검 대상: `codex-teams` 스킬 (`/home/stank/.codex/skills/codex-teams`)
- 점검 목적: 의도한 워크플로우(팀 생성/메시징/제어요청/스웜 오케스트레이션/정리) 정상 동작 여부 확인

## 1) 검증 환경

- Repo: `/mnt/c/Users/송용준/Desktop/any`
- 실행 바이너리
  - `codex-teams`: `/home/stank/.local/bin/codex-teams`
  - `tmux`: `/usr/bin/tmux`
  - `python3`: `/usr/bin/python3`
- `codex-teams --help` 정상 출력 확인

## 2) 테스트 시나리오 및 결과

| ID | 시나리오 | 실행 요약 | 결과 |
|---|---|---|---|
| T1 | CLI 접근성 | `codex-teams --help` | 성공 |
| T2 | 팀 컨텍스트 생성 | `teamcreate --session codex-teams-healthcheck-20260209 --workers 3` | 성공 (`team.json`, `bus.sqlite` 생성) |
| T3 | 메시지 전송 (direct/broadcast/request) | `sendmessage --type message/broadcast/permission_request` | 성공 (fanout 및 inbox 반영 확인) |
| T4 | 메일박스/상태 확인 | `team_mailbox.sh inbox/pending/mark-read`, `team_status.sh` | 성공 (unread 카운트/mark-read 반영) |
| T5 | 스웜 오케스트레이션 | `up --no-attach --workers 1` | 성공 (tmux `swarm`, `team-monitor`, `team-pulse` 생성) |
| T6 | 정리/삭제 | `teamdelete` / `teamdelete --force` | 성공 (세션/디렉터리 정리 확인) |

## 3) 핵심 관찰 로그

### 3.1 teamcreate

- 출력:
  - `team context ready`
  - `file: .../.codex-teams/codex-teams-healthcheck-20260209/team.json`
  - `db: .../.codex-teams/codex-teams-healthcheck-20260209/bus.sqlite`

### 3.2 sendmessage

- direct: `sent message #2 fanout=1`
- broadcast: `sent message #3 fanout=6`
- permission request: `sent message #4 fanout=1`

### 3.3 up --no-attach

- 생성된 tmux window:
  - `swarm`
  - `team-monitor`
  - `team-pulse`
- pane 확인:
  - `director`, `hcpair-1`, `monitor`, `pulse`

## 4) 이슈 수정 결과

### 이슈 A (해결): `team_control.sh request`의 `--summary` 인자 파싱 위치 문제

- 수정 내용:
  - `scripts/team_control.sh`의 `request` 파서를 개선해 `--summary`를 메시지 앞/뒤 어디에 두어도 정상 인식하도록 변경
  - `--summary=value` 형태도 허용
  - usage 예시에 앞/뒤 배치 모두 추가
- 재검증:
  - trailing 케이스: `request ... "ready trailing" --summary "sum-trailing"` 정상
  - leading 케이스: `request --summary "sum-leading" ... "ready leading"` 정상
  - 결과: 둘 다 body는 순수 메시지로 저장되고, meta.summary가 정확히 저장됨

## 5) 스킬 개선 결과 (강제 없음, 자연스러운 사용 유도)

- `agents/openai.yaml` 기본 프롬프트를 개선해 `$codex-teams` 사용 시 아래 협업 루프를 **강제하지 않고 적응형으로** 유도:
  1. 리서치/스코프
  2. 작업 분배
  3. 실시간 협업
  4. 디렉터 리뷰/재수정 판단
  5. 머지 판단
- `SKILL.md`에 Natural Collaboration Loop와 실전 명령 예시(`sendmessage`, `team_send.sh`, `team_control.sh`) 추가
- `references/protocol.md`에 adaptive operating mode 및 `--summary` 동작 명시
- `team_codex.sh`, `team_codex_ma.sh` 런타임 시작 메시지에 협업 루프 가이드를 추가해 세션 내 자연스러운 기능 활용 지원

## 6) 최종 판정

- **판정: 정상**
- 초기 결함(`--summary` 위치 파싱)은 해결되었고 재현 테스트로 확인됨.
- 사용자 의도(오케스트레이터 리서치 -> 분배 -> 실시간 협업 -> 리뷰/재수정 -> 머지 결정)에 맞게, 기능 강제 없이 자연스럽게 전체 기능을 활용하도록 스킬 동작/문서/프롬프트가 개선됨.

## 7) 추가 개선 (자동 머지 + IDE 터미널 운영)

- 자동 머지 오토파일럿 추가:
  - `scripts/team_autopilot.py` 신설
  - `codex-teams run/up --autopilot` 또는 `codex-teams-ma run/up --autopilot` 지원
  - 동작:
    1. director 대상 `plan_approval` pending 감시
    2. 증거/블로커 정책으로 자동 승인/반려
    3. 모든 워커 승인 + 사후 blocker 없음 조건에서 자동 merge 실행
- 검증 결과:
  - 요청 `fd299c2f8b6d`가 `approved by autopilot policy`로 자동 승인됨
  - 이어서 `autopilot merge completed` 상태 메시지 확인
- IDE 운영 방식 변경:
  - 전용 Viewer 확장 의존 제거(문서에서 extension 섹션 삭제)
  - IDE 통합 터미널에서 `tmux attach -t <session>` 또는 `codex-teams-dashboard`로 모니터링하도록 정리
- IDE 자동 에이전트 창:
  - IDE 감지(VS Code/Antigravity) 시 `run/up`에서 `team-ide-agents` 윈도우 자동 생성
  - director/pair-N 별 live stream pane을 자동 구성
  - 수동 제어 옵션: `--ide-view`, `--no-ide-view`, `--ide-window`
  - 검증: `--ide-view` 강제 실행 및 `VSCODE_PID` 기반 auto 모드에서 `team-ide-agents` 생성 확인
- 로컬 확장 제거:
  - `antigravity.antigravity-codex-teams-viewer-0.1.1` 삭제 완료
