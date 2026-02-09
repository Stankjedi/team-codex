# codex-teams 실시간 협업 검증 보고서 (소설 작성 보조 데스크탑 테스트 앱)

작성일: 2026-02-09

## 1. 목표
- `codex-teams` 스킬이 의도한 멀티에이전트 실시간 협업(`scope -> delegate -> peer-qa -> verify -> handoff`)으로 동작하는지 검증
- 검증 과정에서 로컬 전용 소설 작성 보조 데스크탑 테스트 앱을 작성하고 실행/테스트 증거를 남김

## 2. 검증 세션

### 2.1 메인 검증 세션 (tmux, 지속형)
- 세션: `novel-assistant-rt-tmux-20260209`
- 실행 옵션: `--workers auto --teammate-mode tmux --tmux-layout split --no-attach`
- 자동 스케일링 결과: `workers=2`
- 버스 상태 요약:
  - `total_messages=21`
  - kind 분포: `status=10`, `task=3`, `question=3`, `answer=3`, `system=2`

고정 워크플로우 이벤트(버스):
- `workflow-fixed scope->delegate->peer-qa->verify->handoff; policy=adaptive-workers-2..4`

### 2.2 auto worker 상한 검증 (4명)
- 세션: `auto-workers-4-check-20260209`
- 자동 스케일링 이벤트:
  - `auto-worker-scaling selected pairs=4 reason=long-brief,multi-subtasks,cross-domain,wide-scope,complex-change`

결론: task 난이도에 따라 pair 수가 `2~4` 범위에서 자동 선택됨을 확인.

## 3. 실시간 peer Q/A 반복 협업 증거
아래는 `novel-assistant-rt-tmux-20260209` 버스 로그에서 확인한 연속 질의/응답 기록(단발성 아님):

- `id=14` pair-1 -> pair-2 (`question`): schema 필드 호환 질의
- `id=15` pair-2 -> pair-1 (`answer`): 필드 호환 응답
- `id=16` pair-2 -> pair-1 (`question`): save 후 consistency run_id 반환 질의
- `id=17` pair-1 -> pair-2 (`answer`): run_id 포함 payload 합의
- `id=18` pair-1 -> pair-2 (`question`): readability span 클릭 점프 우선순위 질의
- `id=19` pair-2 -> pair-1 (`answer`): 하이라이트 연동 합의
- `id=20` pair-1 -> director (`status`): Q/A 반복 협업 진행 보고
- `id=21` pair-2 -> director (`status`): Q/A 반복 협업 진행 보고

즉, 질문/응답이 1회성으로 끝나지 않고, 통합 포인트를 기준으로 반복 수행됨을 확인.

## 4. 테스트 프로젝트 산출물
루트 워크트리에 통합한 테스트 앱 경로:

- `apps/sandbox/novel-assistant-desktop/app.py`
- `apps/sandbox/novel-assistant-desktop/run_app.bat`
- `apps/sandbox/novel-assistant-desktop/README.md`
- `apps/sandbox/novel-assistant-desktop/novel_assistant/schema.sql`
- `apps/sandbox/novel-assistant-desktop/novel_assistant/db.py`
- `apps/sandbox/novel-assistant-desktop/novel_assistant/consistency.py`
- `apps/sandbox/novel-assistant-desktop/novel_assistant/readability.py`
- `apps/sandbox/novel-assistant-desktop/tests/test_db_consistency.py`
- `apps/sandbox/novel-assistant-desktop/tests/test_readability.py`

## 5. 적용한 개선 사항
- `pair-1`/`pair-2`/`pair-3` 결과물을 통합하여 실제 실행 가능한 단일 앱 구조로 정리
- `novel_assistant/db.py`에 `NovelDB` 어댑터 추가
  - 앱 UI가 SQLite 데이터에 직접 연결되도록 보강
  - 초기 샘플 프로젝트/아크/에피소드/씬 seed 자동 생성
  - `save_scene` 시 일관성 검사(`run_consistency_checks`) 재실행 및 run 정보 반환
- 앱 실행/테스트 방법을 한국어 README에 명시

## 6. 검증 실행 결과

### 6.1 단위 테스트
실행:
```bash
cd apps/sandbox/novel-assistant-desktop
PYTHONPATH=. python3 -m unittest discover -s tests -v
```
결과:
- `Ran 9 tests in 1.047s`
- `OK`

### 6.2 DB 어댑터 스모크 검증
실행 요약:
- `NovelDB().get_story_tree()` 정상 반환
- `NovelDB().get_scene(scene_id)` 정상 반환
- `NovelDB().save_scene(...)` 정상 저장 + consistency 검사 run 생성

출력 예:
- `arcs 1`
- `scene_title 첫 만남`
- `save_ok True issues 1`

## 7. 운영 메모
- 본 실행 환경에서는 `in-process-shared` 백엔드의 백그라운드 허브가 명령 종료 시 유지되지 않는 경우가 있어,
  실시간 협업 검증은 `tmux` 백엔드에서 안정적으로 진행함.
- 실제 팀 협업 검증/관측은 `tmux` 모드를 기본으로 권장.

## 8. 결론
- `codex-teams`의 핵심 협업 계약(고정 워크플로우, auto delegate, peer Q/A 반복, 상태 보고)이 버스 로그로 검증됨.
- pair 에이전트 수 자동 스케일링(2~4) 동작을 확인함.
- 요구한 테스트 프로젝트(소설 작성 보조 데스크탑 앱) 생성 및 로컬 테스트 통과를 완료함.
