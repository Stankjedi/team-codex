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

render_inprocess_agents() {
  local runtime_file="$REPO/.codex-teams/$SESSION/runtime.json"
  local log_dir="$REPO/.codex-teams/$SESSION/logs"

  if [[ ! -f "$runtime_file" ]]; then
    echo "(no runtime state: $runtime_file)"
    return 0
  fi

  local entries
  entries="$(python3 - "$runtime_file" <<'PY'
import json
import sys

runtime_path = sys.argv[1]
try:
    with open(runtime_path, "r", encoding="utf-8") as f:
        runtime = json.load(f)
except Exception:
    raise SystemExit(0)

agents = runtime.get("agents", {})
if not isinstance(agents, dict):
    raise SystemExit(0)

for name in sorted(agents.keys()):
    rec = agents.get(name, {})
    if not isinstance(rec, dict):
        continue
    if str(rec.get("backend", "")) not in {"in-process", "in-process-shared"}:
        continue
    status = str(rec.get("status", ""))
    pid = str(rec.get("pid", 0))
    print(f"{name}|{status}|{pid}")
PY
)"

  if [[ -z "$entries" ]]; then
    echo "(no in-process teammates)"
    return 0
  fi

  while IFS='|' read -r agent status pid; do
    [[ -z "$agent" ]] && continue
    echo ""
    render_section_header "$agent"
    echo "backend=in-process status=$status pid=$pid"
    local log_file="$log_dir/$agent.log"
    if [[ -f "$log_file" ]]; then
      tail -n "$LINES" "$log_file"
    else
      echo "(log missing: $log_file)"
    fi
  done <<< "$entries"
}

render_fs_unread_mailbox() {
  local config_file="$REPO/.codex-teams/$SESSION/config.json"
  local inbox_root="$REPO/.codex-teams/$SESSION/inboxes"
  if [[ ! -f "$config_file" ]]; then
    echo "(no team config: $config_file)"
    return 0
  fi
  python3 - "$config_file" "$inbox_root" <<'PY'
import json
import os
import sys

config_file, inbox_root = sys.argv[1], sys.argv[2]
try:
    with open(config_file, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    print("(failed to read team config)")
    raise SystemExit(0)

members = [m for m in cfg.get("members", []) if isinstance(m, dict)]
if not members:
    print("(no members)")
    raise SystemExit(0)

for member in members:
    name = str(member.get("name", ""))
    if not name:
        continue
    inbox_file = os.path.join(inbox_root, f"{name}.json")
    unread = []
    if os.path.isfile(inbox_file):
        try:
            with open(inbox_file, "r", encoding="utf-8") as f:
                inbox = json.load(f)
            msgs = inbox.get("messages", [])
            if isinstance(msgs, list):
                unread = [m for m in msgs if isinstance(m, dict) and not bool(m.get("read", False))]
        except Exception:
            unread = []
    if not unread:
        print(f"{name}: unread=0")
        continue
    latest = unread[-1]
    print(
        f"{name}: unread={len(unread)} "
        f"latest={latest.get('type','')} from={latest.get('from','')} "
        f"summary={latest.get('summary','')}"
    )
PY
}

render_fs_pending_controls() {
  local control_file="$REPO/.codex-teams/$SESSION/control.json"
  if [[ ! -f "$control_file" ]]; then
    echo "(no control store: $control_file)"
    return 0
  fi
  python3 - "$control_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        control = json.load(f)
except Exception:
    print("(failed to read control store)")
    raise SystemExit(0)

reqs = control.get("requests", {})
if not isinstance(reqs, dict) or not reqs:
    print("(no control requests)")
    raise SystemExit(0)

pending = []
for req in reqs.values():
    if not isinstance(req, dict):
        continue
    if str(req.get("status", "")) != "pending":
        continue
    pending.append(req)

if not pending:
    print("(no pending requests)")
    raise SystemExit(0)

pending.sort(key=lambda r: str(r.get("created_ts", "")))
for req in pending[-20:]:
    print(
        f"request_id={req.get('request_id','')} type={req.get('req_type','')} "
        f"from={req.get('sender','')} to={req.get('recipient','')} created={req.get('created_ts','')}"
    )
    print(f"body={req.get('body','')}")
PY
}

REPO="$(normalize_repo_path "$REPO")"
REPO="$(cd "$REPO" && pwd)"
DB="$REPO/.codex-teams/$SESSION/bus.sqlite"
ORIGINAL_REPO="$REPO"

TMUX_AVAILABLE="false"
TMUX_INSTALLED="false"
if command -v tmux >/dev/null 2>&1; then
  TMUX_INSTALLED="true"
  if tmux has-session -t "$SESSION" >/dev/null 2>&1; then
    TMUX_AVAILABLE="true"
  fi
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

  echo ""
  render_section_header "filesystem inbox (unread)"
  render_fs_unread_mailbox

  echo ""
  render_section_header "control queue (pending)"
  render_fs_pending_controls

  if [[ "$TMUX_AVAILABLE" == "true" ]]; then
    render_tmux_panes
  else
    echo ""
    render_section_header "tmux"
    if [[ "$TMUX_INSTALLED" == "true" ]]; then
      echo "session not found: $SESSION (in-process backend may be running without tmux panes)"
    else
      echo "tmux not installed; showing bus/runtime data only"
    fi
  fi

  echo ""
  render_section_header "in-process teammates"
  render_inprocess_agents

  if [[ "$ONCE" == "true" ]]; then
    break
  fi
  sleep "$INTERVAL"
done
