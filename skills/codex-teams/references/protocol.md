# Codex Teams Protocol

## Team Lifecycle

0. `setup`
- prepares repo prerequisites for `run/up`:
  - initializes git repo when missing
  - creates initial commit when missing
  - ensures local git identity fallback for bootstrap commit

1. `teamcreate`
- creates `.codex-teams/<session>/config.json` and legacy `.codex-teams/<session>/team.json`
- creates filesystem inbox/state/runtime artifacts:
  - `.codex-teams/<session>/inboxes/*.json`
  - `.codex-teams/<session>/control.json`
  - `.codex-teams/<session>/state.json`
  - `.codex-teams/<session>/runtime.json`
- initializes `.codex-teams/<session>/bus.sqlite`
- registers team members in bus (`lead`, `worker-N`, `utility-1`, `system`, `monitor`, `orchestrator`)

2. `run/up`
- selects backend:
  - `tmux` (`--tmux-layout split|window`)
  - `--teammate-mode auto` is accepted and normalized to `tmux`
- `tmux` is required for `run/up` in current single-mode policy
- `tmux` backend starts `swarm` + `team-monitor` + `team-pulse` windows
- emits startup `system` and worker-scaling `status` messages
- `--workers auto` uses adaptive worker-pool scaling in range `2..4`
- emits fixed workflow `status`: `lead-research+plan -> delegate -> peer-qa(iterative) -> on-demand-research-by-lead -> lead-review -> utility-push/merge`
- lead는 orchestration-only로 유지되며 구현 태스크를 직접 수행하지 않음
- default auto-delegates initial task from `lead` to each worker/utility agent with role-specific execution prompt

3. `teamdelete`
- removes team directory (and kills active tmux session when `--force`)

## Roles

- `lead`: orchestration-only, staffing/delegation/intervention owner, worker 요청 시 추가 리서치/재계획을 수행하고 요청 worker에 재전달
- `worker-N`: implementation execution
- `utility-1`: git/release/deploy utility owner
- `monitor`: read-only tail of all traffic
- `system`: lifecycle notices
- `orchestrator`: auto-scaling/coordination notices

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
