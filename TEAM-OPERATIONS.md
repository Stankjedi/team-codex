# Team Operations Spec

## Topology
- `lead` x 1
- `worker` x 2 (default)
- `utility` x 1

## Staffing Policy
- 기본 worker 수는 2
- `--workers auto`에서 worker pool을 2~4로 자동 산정
- worker 최소 인원은 2명으로 강제
- utility는 고정 1명

## Worktree Policy
- lead는 루트 레포가 아니라 전용 worktree(`.worktrees/lead-1` 기본)에서 실행한다.
- worker/utility는 `.worktrees/<agent>`를 사용한다.

## Worker Scale-Out Rule
- 추가 워커가 필요하면 반드시 `worker-N` 워크트리를 먼저 포함한 토폴로지로 실행한다.
- 기본 방법: `codex-teams run --workers <N>` 또는 `codex-teams run --workers auto`
- 위 실행에서 `.worktrees/worker-1..N`과 `ma/worker-1..N` 브랜치가 자동으로 맞춰진다.
- 세션 운영 중 증설이 필요하면, 작업을 재분배하기 전에 목표 워커 수(`N`)로 재실행해 워크트리를 동기화한다.

## Non-Execution Lead Rule
- lead는 오케스트레이션 전용
- 구현/테스트/커밋 직접 수행 금지
- 사용자 입력 기반 리서치/계획 수립, 분배, 중간 개입, 최종 리뷰 수행

## Workflow Contract
1. lead가 사용자 입력 수신 후 리서치/계획 수립
2. worker pool을 볼륨에 맞게 조정하고 작업 분배
3. worker가 중간 질의/요청 시 lead가 추가 리서치와 재계획 수행 후 재전달
4. lead- worker 실시간 협업 및 중간 조정
5. lead 최종 리뷰
6. utility로 인계 후 git push/merge
