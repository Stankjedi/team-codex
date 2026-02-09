# Codex Teams Protocol

## Team Lifecycle

1. `teamcreate`
- creates `.codex-teams/<session>/config.json` and legacy `.codex-teams/<session>/team.json`
- creates filesystem inbox/state/runtime artifacts:
  - `.codex-teams/<session>/inboxes/*.json`
  - `.codex-teams/<session>/control.json`
  - `.codex-teams/<session>/state.json`
  - `.codex-teams/<session>/runtime.json`
- initializes `.codex-teams/<session>/bus.sqlite`
- updates viewer bridge `.codex-teams/.viewer-session.json` (active session metadata for IDE extension)
- registers team members in bus (`director`, `pair-N`, `system`, `monitor`, `orchestrator`)

2. `run/up`
- selects backend:
  - `auto`
  - `tmux` (`--tmux-layout split|window`)
  - `in-process` (filesystem mailbox poll loop)
  - `in-process-shared` (single-process hub running multiple teammate loops)
- `tmux` backend starts `swarm` + `team-monitor` + `team-pulse` windows
- emits startup `system` and worker-scaling `status` messages
- default auto-delegates initial task from `director` to each `pair-N` with role-specific execution prompt

3. `teamdelete`
- removes team directory (and kills active tmux session when `--force`)

## Roles

- `director`: owns planning, integration decision, final review loop
- `pair-N`: scoped implementation workers
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
TEAM_DB=.codex-teams/<session>/bus.sqlite team_mailbox.sh --room main inbox director --unread
team_mailbox.sh --repo . --session <session> --mode fs inbox director --unread --json
team_mailbox.sh --repo . --session <session> --mode fs mark-read director --all
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
- Director emits team-wide `status` every major plan change.
- Blocked worker emits `blocker` immediately.
- Runtime automatically emits `status` events: `online`, `heartbeat`, `offline`.

## Handoff Template

`done: <what changed>; evidence: <tests/commands>; risk: <remaining risk>; next: <recommended next step>`
