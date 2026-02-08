# Codex Teams Protocol

## Roles
- `director`: owns planning, file ownership, integration decision, review loop.
- `worker-N`: owns one scoped implementation stream at a time.
- `monitor`: read-only tail of all traffic.

## Message Kinds
- `task`: assignment with acceptance criteria
- `question`: clarification request
- `answer`: response to a question
- `status`: milestone/progress signal
- `blocker`: cannot continue without intervention
- `system`: bootstrap/session messages

## Message Quality Rules
- Start messages with intent + scope.
- Include concrete artifact names (`file`, `test`, `command`) in status updates.
- For blockers, include at least one proposed workaround.
- Keep payloads <= 3 lines; move long detail to commit diff or file reference.

## Cadence
- Worker sends a `status` at start, after each meaningful milestone, and at handoff.
- Director sends team-wide `status` every 10-15 minutes or after major plan changes.
- Any blocked worker sends `blocker` immediately.

## Handoff Template
Use this exact format:

`done: <what changed>; evidence: <tests/commands>; risk: <remaining risk>; next: <recommended next step>`
