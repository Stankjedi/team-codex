# Codex Teams 실시간 협업 검증 (Unit Converter)

- 날짜: 2026-02-09
- 저장소: `/mnt/c/Users/송용준/Desktop/any`
- 세션: `converter-rt-live`
- 실행 모드: `in-process-shared`

## 목표
1. `codex-teams`가 고정 협업 흐름(`scope -> delegate -> peer-qa -> verify -> handoff`)을 버스에 기록하는지 검증
2. `--workers auto`가 페어를 2~4 범위에서 능동 스폰하는지 검증
3. 새 Windows 테스트 앱(`windows-unit-converter`)을 페어 협업으로 구현하고 동작 검증

## 자동 스폰 검증
실행 명령:
```bash
./skills/codex-teams/scripts/team_codex.sh run \
  --config .codex-multi-agent.allowdirty.config.sh \
  --session converter-rt-live \
  --task "Build a Windows unit converter test app ..." \
  --workers auto \
  --teammate-mode in-process-shared \
  --no-auto-delegate --no-attach
```

결과 요약:
- `workers: 3`
- `worker scaling: auto (multi-subtasks,cross-domain,complex-change)`

버스 증거:
- `id=4`: `auto-worker-scaling selected pairs=3 ...`
- `id=6`: `workflow-fixed scope->delegate->peer-qa->verify->handoff; policy=adaptive-workers-2..4`

## 페어 분업
- `pair-1`: `converter_core.py` + `tests/test_converter_core.py`
- `pair-2`: `converter_app.py` (Tkinter UI)
- `pair-3`: `run_converter.bat`, `README.md`(한국어), `converter_cli.py`

## 실시간 협업 메시지 증거 (요약)
버스 DB: `.codex-teams/converter-rt-live/bus.sqlite`

핵심 흐름:
- director가 pair-1/2/3에 각각 작업 할당 (`id=9~11`)
- pair-2가 pair-1에 API 질의 (`id=13`)
- pair-3가 pair-2에 엔트리포인트 질의 (`id=16`)
- pair-2 완료 보고 + pair-3 전달 (`id=17,18`)
- pair-3 진행/완료 보고 (`id=19,20`)
- pair-1 API 응답 + 완료 보고(보강 메시지) + pair-2 확인 상태 기록

## 로그 파일
- `.codex-teams/converter-rt-live/logs/pair-1-exec.log`
- `.codex-teams/converter-rt-live/logs/pair-2-exec.log`
- `.codex-teams/converter-rt-live/logs/pair-3-exec.log`

## 최종 산출물
- `apps/sandbox/windows-unit-converter/converter_core.py`
- `apps/sandbox/windows-unit-converter/tests/test_converter_core.py`
- `apps/sandbox/windows-unit-converter/converter_app.py`
- `apps/sandbox/windows-unit-converter/converter_cli.py`
- `apps/sandbox/windows-unit-converter/run_converter.bat`
- `apps/sandbox/windows-unit-converter/README.md`

## 검증 결과
- 단위 테스트:
  - `python3 -m unittest discover -s apps/sandbox/windows-unit-converter/tests -v`
  - 결과: `Ran 19 tests ... OK`
- 컴파일 검증:
  - `python3 -m py_compile apps/sandbox/windows-unit-converter/converter_core.py apps/sandbox/windows-unit-converter/converter_app.py apps/sandbox/windows-unit-converter/converter_cli.py`
  - 결과: 통과
- CLI 스모크:
  - `python3 ./apps/sandbox/windows-unit-converter/converter_cli.py 100 cm m` -> `100 cm = 1 m`
  - `python3 ./apps/sandbox/windows-unit-converter/converter_cli.py --value 1 --from-unit kg --to-unit lb` -> `1 kg = 2.20462 lb`
  - `python3 ./apps/sandbox/windows-unit-converter/converter_cli.py 32 f c` -> `32 f = 0 c`

## 결론
`codex-teams`는 이번 검증에서 다음을 충족했다.
- 2~4 범위 능동 스폰 정책(`--workers auto`) 적용
- 고정 협업 흐름 이벤트(`workflow-fixed ...`) 기록
- pair 간 질문/응답 기반 실시간 협업 흔적 확보
- 분업 산출물 통합 후 테스트/컴파일 정상 통과
