# Codex Teams 실시간 협업 검증 보고서 (날씨 위젯, 2026-02-09)

## 목적
`codex-teams`를 에이전트 팀 스타일의 실시간 협업 버스로 사용해 Windows 날씨 위젯 테스트 앱을 제작할 수 있는지 검증한다.

## 적용한 개선
1. 글로벌 `codex-teams` 런처를 로컬 최신 스킬 버전으로 갱신
- 명령: `./skills/codex-teams/scripts/install_global.sh --link`
- 확인: `codex-teams --help`에 `--teammate-mode auto|tmux|in-process|in-process-shared` 노출

2. 버스 직접 검증용 `sqlite3` 설치
- 경로: `/home/stank/.local/bin/sqlite3`
- 버전: `3.51.2`

3. 로컬 검증을 위한 dirty worktree 허용 설정 추가
- `.codex-multi-agent.allowdirty.config.sh`

## 사용 세션
- 세션: `weather-rt-live`
- DB: `.codex-teams/weather-rt-live/bus.sqlite`

## 실시간 협업 증거
아래 메시지 흐름으로 멀티에이전트 실시간 협업(디렉터 분배, pair 간 API 교환, 진행/완료 보고)을 확인했다.

```sql
sqlite3 .codex-teams/weather-rt-live/bus.sqlite \
  ".mode column" ".headers on" \
  "select id,ts,kind,sender,recipient,substr(body,1,140) as body from messages order by id;"
```

관찰된 주요 순서(요약):
- `id=3` director -> pair-2: UI 슬라이스 할당
- `id=4` director -> pair-1: 백엔드 슬라이스 할당
- `id=5` pair-1 -> director: 백엔드 구현 시작
- `id=6` pair-1 -> pair-2: API 계약 공유
- `id=7` pair-2 -> pair-1: API 질의
- `id=8` pair-2 -> director: 진행 보고
- `id=9` pair-1 -> director: 백엔드+테스트 완료 보고
- `id=10` pair-2 -> director: UI 완료 보고
- `id=11` pair-2 -> pair-1: 통합 완료 전달

수신자별 메일박스 적재도 확인:

```sql
sqlite3 .codex-teams/weather-rt-live/bus.sqlite \
  ".mode column" ".headers on" \
  "select id,recipient,message_id,state,created_ts from mailbox where recipient in ('director','pair-1','pair-2') order by id desc limit 30;"
```

## 페어별 소유 범위
- pair-1 산출물
  - `apps/sandbox/windows-weather-widget/weather_service.py`
  - `apps/sandbox/windows-weather-widget/tests/test_weather_service.py`

- pair-2 산출물
  - `apps/sandbox/windows-weather-widget/widget.py`
  - `apps/sandbox/windows-weather-widget/run_widget.bat`
  - `apps/sandbox/windows-weather-widget/README.md`

## 최종 검증
`apps/sandbox/windows-weather-widget` 기준:
- `python3 -m unittest discover -s tests -v` -> `7 passed`
- `python3 -m py_compile weather_service.py widget.py` -> 통과

## 참고
이 실행 환경에서는 one-shot 세션에서 분리 실행된 `in-process`/`in-process-shared` 워커가 짧게 종료될 수 있다. 따라서 본 검증은 `codex-teams` 메시지 계약(`sendmessage` + SQLite 확인)과 동시 실행된 pair 워커 로그를 함께 사용해 실시간 협업을 검증했다.
