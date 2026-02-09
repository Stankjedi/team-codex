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
Terminal dashboard for codex-teams sessions.

Usage:
  team_dashboard.sh [options]

Options:
  --session NAME    tmux session name (default: codex-fleet)
  --repo PATH       repo root that owns .codex-teams (default: current directory)
  --room NAME       bus room name (default: main)
  --interval SEC    refresh interval seconds (default: 1)
  --lines N         pane lines captured per pane (default: 14)
  --messages N      recent bus messages to show (default: 14)
  --once            render one frame and exit
  -h, --help        show help

Examples:
  team_dashboard.sh --session codex-fleet --repo /path/to/repo --room main
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

find_repo_with_bus_db() {
  local start="$1"
  local path
  path="$(cd "$start" 2>/dev/null && pwd || true)"
  if [[ -z "$path" ]]; then
    return 1
  fi

  while true; do
    if [[ -f "$path/.codex-teams/$SESSION/bus.sqlite" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
    if [[ "$path" == "/" ]]; then
      break
    fi
    path="$(dirname "$path")"
  done
  return 1
}

discover_repo_from_tmux_session() {
  local pane_path
  while IFS= read -r pane_path; do
    [[ -z "$pane_path" ]] && continue

    if inferred="$(find_repo_with_bus_db "$pane_path" 2>/dev/null)"; then
      printf '%s\n' "$inferred"
      return 0
    fi

    if command -v git >/dev/null 2>&1 && git -C "$pane_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      local common_dir
      common_dir="$(git -C "$pane_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
      if [[ -n "$common_dir" ]]; then
        local common_root
        common_root="$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd || true)"
        if [[ -n "$common_root" && -f "$common_root/.codex-teams/$SESSION/bus.sqlite" ]]; then
          printf '%s\n' "$common_root"
          return 0
        fi
      fi
    fi
  done < <(tmux list-panes -s -t "$SESSION" -F "#{pane_current_path}" 2>/dev/null || true)
  return 1
}

render_messages() {
  if [[ ! -f "$DB" ]]; then
    echo "(no bus db: $DB)"
    return 0
  fi

  python3 - "$DB" "$ROOM" "$MSG_LIMIT" <<'PY'
import sqlite3
import sys

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

pane_label() {
  local window_name="$1"
  local pane_index="$2"
  local pane_title="$3"
  if [[ -n "$pane_title" ]]; then
    printf '%s\n' "$pane_title"
    return 0
  fi
  printf '%s.%s\n' "$window_name" "$pane_index"
}

render_one_pane() {
  local window_name="$1"
  local pane_index="$2"
  local pane_id="$3"
  local pane_title="$4"
  local pane_cmd="$5"

  local title
  title="$(pane_label "$window_name" "$pane_index" "$pane_title")"

  echo ""
  render_section_header "$title"
  echo "pane=$pane_id window=$window_name cmd=$pane_cmd"
  tmux capture-pane -pt "$SESSION:$window_name.$pane_index" -S "-$LINES" 2>/dev/null || echo "(unavailable)"
}

render_tmux_panes() {
  local window_name
  while IFS= read -r window_name; do
    [[ -z "$window_name" ]] && continue
    while IFS='|' read -r pane_index pane_id pane_title pane_cmd; do
      [[ -z "$pane_id" ]] && continue
      render_one_pane "$window_name" "$pane_index" "$pane_id" "$pane_title" "$pane_cmd"
    done < <(tmux list-panes -t "$SESSION:$window_name" -F "#{pane_index}|#{pane_id}|#{pane_title}|#{pane_current_command}" 2>/dev/null || true)
  done < <(tmux list-windows -t "$SESSION" -F "#{window_name}")
}

REPO="$(normalize_repo_path "$REPO")"
REPO="$(cd "$REPO" && pwd)"
DB="$REPO/.codex-teams/$SESSION/bus.sqlite"
ORIGINAL_REPO="$REPO"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required" >&2
  exit 2
fi

TMUX_AVAILABLE="false"
if tmux has-session -t "$SESSION" >/dev/null 2>&1; then
  TMUX_AVAILABLE="true"
fi

if [[ "$TMUX_AVAILABLE" == "true" && ! -f "$DB" ]]; then
  auto_repo="$(discover_repo_from_tmux_session || true)"
  if [[ -n "$auto_repo" && "$auto_repo" != "$REPO" ]]; then
    REPO="$auto_repo"
    DB="$REPO/.codex-teams/$SESSION/bus.sqlite"
  fi
fi

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
    if [[ "$REPO" != "$ORIGINAL_REPO" ]]; then
      echo "note: repo path auto-corrected from $ORIGINAL_REPO to $REPO based on tmux session"
      echo "hint: set dashboard repo/session to match the active run"
    fi
  fi

  echo ""
  render_section_header "Recent Messages"
  render_messages

  if [[ "$TMUX_AVAILABLE" == "true" ]]; then
    render_tmux_panes
  else
    echo ""
    render_section_header "tmux"
    echo "session not found: $SESSION (in-process backend may be running without tmux panes)"
  fi

  if [[ "$ONCE" == "true" ]]; then
    break
  fi
  sleep "$INTERVAL"
done
