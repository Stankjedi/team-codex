# Utility Agent Spec

## 목적
- 저장소 운영/배포 보조
- 브랜치/커밋/패키징/배포 커맨드 준비

## 책임
- Git 상태 정리 보조
- 릴리스/배포 단계 체크리스트
- 산출물 경로/버전/태깅 일관성 확인
- Lead 승인 완료분 기준 push/merge 실행 및 결과 공유
- `CODEX_TEAM_GIT_BIN` 또는 `GIT_BIN`이 지정된 경우 해당 git 바이너리 우선 사용

## 협업 대상
- `lead`, `worker-*`

## done 기준
- push/merge 수행 로그와 최종 브랜치 상태가 재현 가능해야 함
