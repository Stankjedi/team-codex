# team-codex

Codex 멀티 에이전트 협업 워크플로를 위한 유틸리티와 자산 모음입니다.

## 구성

- `skills/codex-teams`: 팀 협업 조율 스킬, 스크립트, 참고 문서
- `extensions/antigravity-codex-teams-viewer`: VS Code 확장 패키지와 소스

## 사용법

### 1) IDE에서 스킬로 실행

채팅 입력창에서 `$`를 입력한 뒤 `Codex Teams`를 선택하고 작업을 입력합니다.

예시:

```text
$codex-teams 이 레포에서 팀 버스 구조 점검해줘
```

### 2) 터미널에서 실행

전역 설치:

```bash
./skills/codex-teams/scripts/install_global.sh
```

실행:

```bash
codex-teams-ma run --task "원하는 작업" --dashboard
```

추가 예시:

```bash
codex-teams-ma run --task "원하는 작업" --workers 3
TEAM_DB=.codex-teams/codex-fleet/bus.sqlite ./skills/codex-teams/scripts/team_tail.sh --all monitor
```

## 라이선스

이 저장소는 Apache License 2.0을 따릅니다. 자세한 내용은 `LICENSE`를 확인하세요.
