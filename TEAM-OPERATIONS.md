# Team Operations Spec

## Topology
- `lead` x 1 (external: current Codex IDE session)
- `worker` x 3 (fixed)

## Staffing Policy
- worker 수는 고정 3 (`worker-1`, `worker-2`, `worker-3`)
- `--workers`는 `3`만 허용

## Worktree Policy
- lead는 현재 Codex 세션(루트 레포)에서 오케스트레이션을 수행한다.
- worker는 `.worktrees/<agent>`를 사용한다.

## Non-Execution Lead Rule
- lead는 오케스트레이션 전용
- 구현/테스트/커밋 직접 수행 금지
- 사용자 입력 기반 리서치/계획 수립, 분배, 중간 개입, 최종 리뷰 수행

## Workflow Contract
1. lead가 사용자 입력 수신 후 리서치/계획 수립
2. 고정 worker(`worker-1`, `worker-2`, `worker-3`)에 작업 분배
3. worker가 중간 질의/요청 시 lead가 추가 리서치와 재계획 수행 후 재전달
4. lead- worker 실시간 협업 및 중간 조정
5. lead 최종 리뷰
6. 승인된 변경은 지정 worker가 git push/merge 수행
