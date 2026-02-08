#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_SCRIPT="$SCRIPT_DIR/team_status.sh"

SESSION="codex-fleet"
REPO="$(pwd)"
ROOM="main"
INTERVAL="1"
LINES="14"
MSG_LIMIT="14"
ONCE="false"

usage() {
  cat <<'EOF'
Terminal dashboard for codex-teams/codex-ma sessions.

Usage:
  team_dashboard.sh [options]

Options:
  --session NAME    tmux session name (default: codex-fleet)
  --repo PATH       repo root that owns .codex-teams (default: current directory)
  --room NAME       bus room name (default: main)
  --interval SEC    refresh interval seconds (default: 1)
  --lines N         pane lines captured per role (default: 14)
  --messages N      recent bus messages to show (default: 14)
  --once            render one frame and exit
  -h, --help        show help

Examples:
  team_dashboard.sh --session teams-rt-test --repo /path/to/repo --room dev
  team_dashboard.sh --session codex-fleet --messages 25 --lines 20
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --room)
      ROOM="$2"
      shift 2
      ;;
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --lines)
      LINES="$2"
      shift 2
      ;;
    --messages)
      MSG_LIMIT="$2"
      shift 2
      ;;
    --once)
      ONCE="true"
      shift
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

if ! [[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--interval must be numeric" >&2
  exit 2
fi
if ! [[ "$LINES" =~ ^[0-9]+$ ]] || [[ "$LINES" -lt 1 ]]; then
  echo "--lines must be an integer >= 1" >&2
  exit 2
fi
if ! [[ "$MSG_LIMIT" =~ ^[0-9]+$ ]] || [[ "$MSG_LIMIT" -lt 1 ]]; then
  echo "--messages must be an integer >= 1" >&2
  exit 2
fi

normalize_repo_path() {
  local p="$1"
  # Convert Windows paths (e.g., C:\Users\me or C:/Users/me) to WSL paths.
  if [[ "$p" =~ ^[A-Za-z]:[\\/].* ]]; then
    if command -v wslpath >/dev/null 2>&1; then
      wslpath -a "$p"
      return 0
    fi
    local drive="${p:0:1}"
    local rest="${p:2}"
    rest="${rest//\\//}"
    printf '/mnt/%s%s\n' "${drive,,}" "$rest"
    return 0
  fi
  printf '%s\n' "$p"
}

REPO="$(normalize_repo_path "$REPO")"
REPO="$(cd "$REPO" && pwd)"
DB="$REPO/.codex-teams/$SESSION/bus.sqlite"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required" >&2
  exit 2
fi

if ! tmux has-session -t "$SESSION" >/dev/null 2>&1; then
  echo "tmux session not found: $SESSION" >&2
  exit 2
fi

render_messages() {
  if [[ ! -f "$DB" ]]; then
    echo "(no bus db: $DB)"
    return 0
  fi

  python3 - "$DB" "$ROOM" "$MSG_LIMIT" <<'PY'
import sqlite3, sys

db, room, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
conn = sqlite3.connect(db)
rows = conn.execute(
    """
    SELECT id, ts, kind, sender, recipient, body
    FROM messages
    WHERE room=?
    ORDER BY id DESC
    LIMIT ?
    """,
    (room, limit),
).fetchall()
for r in reversed(rows):
    print(f"[{r[0]:06d}] {r[1]} {r[2]} {r[3]} -> {r[4]}: {r[5]}")
PY
}

render_rule() {
  local char="${1:--}"
  local width="${2:-}"

  if [[ -z "$width" ]]; then
    if [[ -n "${COLUMNS:-}" ]] && [[ "$COLUMNS" =~ ^[0-9]+$ ]] && [[ "$COLUMNS" -ge 20 ]]; then
      width="$COLUMNS"
    elif [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
      width="$(tput cols 2>/dev/null || true)"
    fi
  fi

  if ! [[ "$width" =~ ^[0-9]+$ ]] || [[ "$width" -lt 20 ]]; then
    width="80"
  fi

  printf '%*s\n' "$width" '' | tr ' ' "$char"
}

render_section_header() {
  local title="$1"
  render_rule "-"
  echo "===== $title ====="
  render_rule "-"
}

render_pane() {
  local window_name="$1"
  echo ""
  render_section_header "$window_name"
  tmux capture-pane -pt "$SESSION:$window_name.0" -S "-$LINES" 2>/dev/null || echo "(unavailable)"
}

while true; do
  if [[ -t 1 ]]; then
    clear || true
  else
    printf '\n'
  fi
  echo "Codex Teams Dashboard"
  echo "session=$SESSION room=$ROOM repo=$REPO"
  echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  if [[ -f "$DB" ]]; then
    TEAM_DB="$DB" "$STATUS_SCRIPT" --room "$ROOM" || true
  else
    echo "db missing: $DB"
  fi

  echo ""
  render_section_header "Recent Messages"
  render_messages

  while IFS= read -r win; do
    [[ -z "$win" ]] && continue
    render_pane "$win"
  done < <(tmux list-windows -t "$SESSION" -F "#{window_name}")

  if [[ "$ONCE" == "true" ]]; then
    break
  fi
  sleep "$INTERVAL"
done
