#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"

DB="${TEAM_DB:-}"
SESSION="codex-fleet"
WINDOW="swarm"
ROOM="main"
PREFIX="pair"
COUNT="4"
LEAD_NAME="director"
LINES="20"
INTERVAL="8"
MIN_GAP="45"

usage() {
  cat <<'EOF'
Emit automatic worker heartbeat status by watching tmux pane content changes.

Usage:
  team_pulse.sh [options]

Options:
  --db PATH         SQLite bus path (or use TEAM_DB)
  --session NAME    tmux session name (default: codex-fleet)
  --window NAME     tmux window name to watch (default: swarm)
  --room NAME       bus room (default: main)
  --prefix NAME     worker pane prefix (default: pair)
  --count N         worker count ceiling (default: 4)
  --lead-name NAME  leader pane title/name (default: director)
  --lines N         pane lines sampled for hash (default: 20)
  --interval SEC    polling interval (default: 8)
  --min-gap SEC     min seconds between emits per agent (default: 45)
  -h, --help        show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)
      DB="$2"
      shift 2
      ;;
    --session)
      SESSION="$2"
      shift 2
      ;;
    --window)
      WINDOW="$2"
      shift 2
      ;;
    --room)
      ROOM="$2"
      shift 2
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --count)
      COUNT="$2"
      shift 2
      ;;
    --lead-name)
      LEAD_NAME="$2"
      shift 2
      ;;
    --lines)
      LINES="$2"
      shift 2
      ;;
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --min-gap)
      MIN_GAP="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$DB" ]]; then
  echo "TEAM_DB not set and --db not provided" >&2
  exit 1
fi
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
  echo "--count must be >= 1" >&2
  exit 2
fi
if ! [[ "$LINES" =~ ^[0-9]+$ ]] || [[ "$LINES" -lt 5 ]]; then
  echo "--lines must be >= 5" >&2
  exit 2
fi
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -lt 1 ]]; then
  echo "--interval must be >= 1" >&2
  exit 2
fi
if ! [[ "$MIN_GAP" =~ ^[0-9]+$ ]] || [[ "$MIN_GAP" -lt 1 ]]; then
  echo "--min-gap must be >= 1" >&2
  exit 2
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required" >&2
  exit 2
fi

if ! tmux has-session -t "$SESSION" >/dev/null 2>&1; then
  echo "tmux session not found: $SESSION" >&2
  exit 2
fi

agent_from_title() {
  local title="$1"
  if [[ "$title" == "$LEAD_NAME" ]]; then
    printf '%s\n' "$LEAD_NAME"
    return 0
  fi
  if [[ "$title" =~ ^${PREFIX}-([0-9]+)$ ]]; then
    local idx="${BASH_REMATCH[1]}"
    if [[ "$idx" -ge 1 && "$idx" -le "$COUNT" ]]; then
      printf '%s\n' "$title"
      return 0
    fi
  fi
  return 1
}

touch_agent() {
  local agent="$1"
  local role="worker"
  if [[ "$agent" == "$LEAD_NAME" ]]; then
    role="director"
  fi
  python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "$agent" --role "$role" >/dev/null 2>&1 || true
}

send_pulse() {
  local agent="$1"
  local body="$2"
  python3 "$BUS" --db "$DB" send --room "$ROOM" --from "$agent" --to "$LEAD_NAME" --kind status --body "$body" >/dev/null 2>&1 || true
}

hash_pane() {
  local pane_id="$1"
  tmux capture-pane -pt "$pane_id" -S "-$LINES" 2>/dev/null | sha1sum | awk '{print $1}'
}

list_target_panes() {
  if [[ -n "$WINDOW" ]] && tmux list-windows -t "$SESSION" -F "#{window_name}" | grep -Fxq "$WINDOW"; then
    tmux list-panes -t "$SESSION:$WINDOW" -F "#{pane_id}|#{window_name}|#{pane_title}" 2>/dev/null || true
  else
    tmux list-panes -s -t "$SESSION" -F "#{pane_id}|#{window_name}|#{pane_title}" 2>/dev/null || true
  fi
}

declare -A LAST_HASH
declare -A LAST_SENT

watch_once() {
  local now
  now="$(date +%s)"

  while IFS='|' read -r pane_id window_name pane_title; do
    [[ -z "$pane_id" ]] && continue
    [[ -z "$pane_title" ]] && continue

    local agent
    if ! agent="$(agent_from_title "$pane_title")"; then
      continue
    fi

    touch_agent "$agent"

    local h
    h="$(hash_pane "$pane_id")"
    if [[ -z "$h" ]]; then
      continue
    fi

    if [[ "${LAST_HASH[$agent]:-}" != "$h" ]]; then
      local last="${LAST_SENT[$agent]:-0}"
      if (( now - last >= MIN_GAP )); then
        send_pulse "$agent" "heartbeat pane=$pane_id window=$window_name title=$pane_title changed=true"
        LAST_SENT[$agent]="$now"
      fi
      LAST_HASH[$agent]="$h"
    fi
  done < <(list_target_panes)
}

while tmux has-session -t "$SESSION" >/dev/null 2>&1; do
  watch_once
  sleep "$INTERVAL"
done
