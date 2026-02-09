# Windows Calendar App

`Tkinter` 기반의 간단한 윈도우 데스크톱 달력 앱입니다.

## 기능

- 월 단위 달력 보기(이전/다음 달 이동, 오늘 이동)
- 날짜별 일정 추가/수정/삭제
- 일정 있는 날짜 하이라이트
- 이벤트 JSON 파일 자동 저장

## 실행

```bash
python3 apps/sandbox/windows-calendar/main.py
```

Windows에서 Python 설치 후 동일하게 실행하면 됩니다.

## 데이터 저장 위치

- Windows: `%APPDATA%\\CodexCalendar\\events.json`
- 기타 환경: `~/.codex-calendar/events.json`

## 테스트

```bash
python3 -m unittest apps/sandbox/windows-calendar/tests/test_calendar_core.py -v
```
