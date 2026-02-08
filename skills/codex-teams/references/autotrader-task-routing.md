# AutoTrader Plan Routing (Task 00-12)

Use this when the user provides the staged AutoTrader plan and asks for fast parallel delivery.

## Suggested Wave Plan

### Wave 1 (Foundation)
- Worker-1: Task 00 (pnpm monorepo scaffold)
- Worker-2: Task 01 (Electron + React + security defaults)
- Worker-3: Task 03 (`services/core` HTTP + WS contracts)
- Director: guardrails (`AGENTS.md`, `.codex/config.toml`), review integration order

### Wave 2 (Desktop/Core Link)
- Worker-1: Task 02 (Binance-like layout skeleton)
- Worker-2: Task 04 (Desktop ↔ Core WS binding + reconnect + logs)
- Worker-3: strengthen shared schemas/tests in `packages/shared`

### Wave 3 (Trading + Risk + Memory Base)
- Worker-1: Task 05 (paper trading + event sourcing)
- Worker-2: Task 06 (risk engine hard rules + UI preview)
- Worker-3: Task 07 (Trade Memory v1 schema + UI)

### Wave 4 (LLM + Search + Embedding)
- Worker-1: Task 08 (Responses API client + structured output)
- Worker-2: Task 09 (web_search evidence pack + citations)
- Worker-3: Task 10 (embedding recall Top-K)

### Wave 5 (Automation + Packaging)
- Worker-1: Task 11 (fill-time note enhancement + audit log)
- Worker-2: Task 12 (desktop packaging + core child-process lifecycle)
- Director: final integration, safety review, and runbook verification

## Bus Message Examples

### Director Assignment
`TEAM_DB=.codex-teams/bus.sqlite ./scripts/team_send.sh --kind task director worker-2 "Own Task 04: WS reconnect + Logs tab rendering + tests"`

### Worker Blocker
`TEAM_DB=.codex-teams/bus.sqlite ./scripts/team_send.sh --kind blocker worker-2 director "Need shared event schema change in packages/shared before decode test can pass"`

### Handoff
`TEAM_DB=.codex-teams/bus.sqlite ./scripts/team_send.sh --kind status worker-1 director "done: Task05 engine+sqlite; evidence: pnpm --filter core test; risk: mock feed volatility tuning"`
