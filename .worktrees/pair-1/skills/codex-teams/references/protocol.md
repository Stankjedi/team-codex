# Codex Teams Protocol

## Team Lifecycle

1. `teamcreate`
- creates `.codex-teams/<session>/team.json`
- initializes `.codex-teams/<session>/bus.sqlite`
- registers team members in bus (`director`, `pair-N`, `system`, `monitor`, `orchestrator`)

2. `run/up`
- launches tmux `swarm` split panes (`director` + `pair-N`)
- starts monitor and pulse helpers
- emits startup `system` and worker-scaling `status` messages

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
- `plan_approval_request`, `plan_approval_response`
- `permission_request`, `permission_response`

## Mailbox State

- every send writes to room log table: `messages`
- fanout recipients get mailbox rows: `mailbox` (`unread`/`read`)
- broadcast (`--to all`) excludes sender and fans out to active members

Useful commands:

```bash
TEAM_DB=.codex-teams/<session>/bus.sqlite team_mailbox.sh --room main inbox director --unread
TEAM_DB=.codex-teams/<session>/bus.sqlite team_mailbox.sh --room main mark-read director --all
```

## Control Requests

- `team_control.sh request --type plan_approval|shutdown|permission ...`
- each request gets stable `request_id`
- `team_control.sh respond --request-id <id> --approve|--reject ...`
- pending queue via `team_mailbox.sh --room main pending <agent>`

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
