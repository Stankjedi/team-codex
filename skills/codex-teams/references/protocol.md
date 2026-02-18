# Codex Teams Protocol

## Team Lifecycle

Platform:
- Windows host + WSL runtime only
- Linux/macOS native runtime is out of scope
- Target repository path must be on Windows mount (`/mnt/<drive>/...`)
- feature gates must be enabled:
  - `CODEX_EXPERIMENTAL_AGENT_TEAMS=1`
  - `CODEX_TEAMS_GATE_TENGU_AMBER_FLINT=1`

0. `setup`
- prepares repo prerequisites for `run/up`:
  - initializes git repo when missing
  - creates initial commit when missing
  - ensures local git identity fallback for bootstrap commit

1. `teamcreate` (explicit/manual path)
- creates `.codex-teams/<session>/config.json` and legacy `.codex-teams/<session>/team.json`
- creates filesystem inbox/state/runtime artifacts:
  - `.codex-teams/<session>/inboxes/*.json`
  - `.codex-teams/<session>/control.json`
  - `.codex-teams/<session>/state.json`
  - `.codex-teams/<session>/runtime.json`
- initializes `.codex-teams/<session>/bus.sqlite`
- registers team members in bus (`lead`, `reviewer-1`, `worker-1`, `worker-2`, `worker-3`, `system`, `monitor`, `orchestrator`)

2. `run/up`
- always performs TeamCreate-equivalent refresh internally before runtime bootstrap
- selects backend:
  - only supported mode: `in-process-shared`
  - `auto` is accepted as compatibility alias and resolves to `in-process-shared`
- `in-process-shared` backend runs a single shared hub process and supervises reviewer-1 + worker-1/2/3 loops
- mailbox handling is mention-driven with backlog draining when queues exceed batch size
- worker completion for lead review is derived from shared-hub runtime state (successful worker run + no pending queue), not free-form done keyword parsing
- default perf knobs:
  - `TEAMMATE_MODE=in-process-shared`
  - `INPROCESS_POLL_MS=250`
- emits startup `system` status messages
- fixed worker pool policy: `worker-1`, `worker-2`, `worker-3` only (`--workers` accepts only `3`) + fixed reviewer `reviewer-1`
- emits fixed workflow `status`: `lead-research+plan -> delegate(workers) -> peer-qa(continuous) -> on-demand-research-by-lead -> worker-complete -> parallel-review(lead+reviewer) -> review-compare -> issue-redelegate(if-needed) -> assigned-worker-push/merge`
- worker completion/results are also shared to peer workers as `peer-sync` collaboration updates to keep cross-worker context aligned
- lead는 orchestration-only로 유지되며 구현 태스크를 직접 수행하지 않음
- default auto-delegates initial task from `lead` to each worker agent with role-specific execution prompt
- reviewer는 review-only 계약으로 실행되며 코드/설정 수정 없이 리뷰 결과만 lead에 전달

3. `teamdelete`
- removes team directory (and force-kills active runtime agents when `--force`)

## Roles

- `lead`: orchestration-only (external current session), delegation/intervention owner, worker 질문 수신 시 리서치 후 `answer/task`로 재전달
- `reviewer-1`: review-only execution, 독립 리뷰 수행 후 결과를 lead에 보고
- `worker-1`, `worker-2`, `worker-3`: implementation execution
- `monitor`: read-only tail of all traffic
- `system`: lifecycle notices
- `orchestrator`: coordination notices
- fixed topology contract: `lead(external) + reviewer-1 + worker-1 + worker-2 + worker-3`

## Message Kinds

Core kinds:
- `task`, `question`, `answer`, `status`, `blocker`, `system`

TeamCreate/SendMessage kinds:
- `message`, `broadcast`
- `shutdown_request`, `shutdown_response`
- `shutdown_approved`, `shutdown_rejected`
- `plan_approval_request`, `plan_approval_response`
- `permission_request`, `permission_response`
- `mode_set_request`, `mode_set_response`

## Mailbox State

- SQLite bus:
  - every send writes to `messages`
  - fanout recipients get `mailbox` rows (`unread`/`read`)
  - broadcast excludes sender and fans out to active members
- Filesystem mailbox:
  - every send/dispatch writes JSON to `inboxes/<agent>.json`
  - each message has `read` flag and optional `request_id` / `approve`

Useful commands:

```bash
TEAM_DB=.codex-teams/<session>/bus.sqlite team_mailbox.sh --room main inbox lead --unread
team_mailbox.sh --repo . --session <session> --mode fs inbox lead --unread --json
team_mailbox.sh --repo . --session <session> --mode fs mark-read lead --all
```

## Control Requests

- `team_control.sh request --type plan_approval|shutdown|permission ...`
- each request gets stable `request_id`
- `team_control.sh respond --request-id <id> --approve|--reject ...`
- FS control store (`control.json`) is the authority for worker/runtime control handling; SQLite is mirrored when available
- responses require an existing request id record; missing/invalid `request_id` synthetic responses are not emitted
- pending queue via:
  - DB mode: `team_mailbox.sh --room main pending <agent>`
  - FS mode: `team_mailbox.sh --repo . --session <session> --mode fs pending <agent>`
- lifecycle is mirrored to `.codex-teams/<session>/control.json` (`pending` -> `approved|rejected`)

## Quality Rules

- Start with intent + scope.
- Include concrete artifacts (`file`, `test`, `command`) in status updates.
- For blockers, always include at least one workaround.
- Keep payload concise; move long details to commit diff/file refs.

## Cadence

- Worker emits `status` at start, each milestone, and handoff.
- Lead emits team-wide `status` every major plan change.
- Blocked worker emits `blocker` immediately.
- Runtime automatically emits `status` events: `online`, `heartbeat`, `offline`.

## Handoff Template

`done: <what changed>; evidence: <tests/commands>; risk: <remaining risk>; next: <recommended next step>`
