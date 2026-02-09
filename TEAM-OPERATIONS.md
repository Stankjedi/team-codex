# Team Operations Spec

## Topology
- `lead` x 1
- `worker` x N (auto-variable)
- `utility` x 1

## Staffing Policy
- `--workers auto`에서 worker pool을 2~4로 자동 산정
- worker 최소 인원은 2명으로 강제
- utility는 고정 1명

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
