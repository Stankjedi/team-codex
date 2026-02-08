# Antigravity Codex Teams Viewer

WSL 원격 환경에서 실행 중인 `codex-teams` / `codex-ma` tmux 세션을 VS Code(또는 Antigravity OpenVSX 기반 IDE)에서 실시간으로 확인하는 확장입니다.

## 제공 UI

- **왼쪽 Activity Bar 패널**: `Codex Teams` 아이콘 + `Live Dashboard` 사이드바 뷰
- **팝아웃 패널**: 명령으로 별도 패널 열기 (`Codex Teams Viewer: Open Dashboard`)

## 기능

- `Codex Teams Viewer: Focus Sidebar` 명령으로 왼쪽 패널 포커스
- `Codex Teams Viewer: Open Dashboard` 명령으로 우측 팝아웃 뷰 열기
- `codex-teams-dashboard --once` 결과를 주기적으로 갱신해서 표시
- `director`, `pair-N`, `system`, `orchestrator`를 색상으로 구분해 에이전트 식별성 강화
- 세션/룸/레포 경로를 명령에서 즉시 변경 가능
- WSL(remote workspace)에서 tmux 세션 출력 확인 가능

## 전제 조건

- WSL 쪽에 `tmux` 설치
- `codex-teams` 스킬 설치 (`codex-teams-dashboard` 커맨드 사용 가능)
- 팀 세션 실행 중

예시:

```bash
codex-teams-ma run --task "implement feature" --dashboard
```

`--workers`를 생략하면 오케스트레이터가 작업량을 보고 pair 수를 2~4 범위에서 자동 결정합니다.

## 설정

- `agCodexTeamsViewer.session` (default: `codex-fleet`)
- `agCodexTeamsViewer.room` (default: `main`)
- `agCodexTeamsViewer.repoPath` (default: `${workspaceFolder}`)
- `agCodexTeamsViewer.refreshMs` (default: `1200`)
- `agCodexTeamsViewer.lines` (default: `18`)
- `agCodexTeamsViewer.messages` (default: `24`)
- `agCodexTeamsViewer.dashboardCommand` (optional custom path)
- `agCodexTeamsViewer.autoOpenOnStartup` (default: `true`)

## OpenVSX 패키징

```bash
cd extensions/antigravity-codex-teams-viewer
npm install
npx @vscode/vsce package
```

생성된 `.vsix`를 OpenVSX 호환 환경에 설치하세요.
