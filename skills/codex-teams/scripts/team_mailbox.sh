#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"
FS="$SCRIPT_DIR/team_fs.py"

DB="${TEAM_DB:-}"
ROOM="main"
REPO=""
SESSION=""
MODE="auto"

usage() {
  cat <<'EOF'
Usage:
  team_mailbox.sh [--db PATH] [--room NAME] [--repo PATH --session NAME] [--mode auto|db|fs] <command> [args]

Commands:
  register <agent> [role]
  members [--json]
  inbox <agent> [--unread] [--mark-read] [--json] [--limit N]
  mark-read <agent> [--all | --id N ...]
  pending <agent> [--all-status] [--json] [--limit N]

Examples:
  TEAM_DB=.codex-teams/codex-fleet/bus.sqlite team_mailbox.sh inbox director --unread
  team_mailbox.sh --repo . --session codex-fleet --mode fs inbox director --unread
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)
      DB="$2"
      shift 2
      ;;
    --room)
      ROOM="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --session)
      SESSION="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [[ -n "$REPO" ]]; then
  REPO="$(cd "$REPO" && pwd)"
fi
if [[ -z "$DB" && -n "$REPO" && -n "$SESSION" ]]; then
  DB="$REPO/.codex-teams/$SESSION/bus.sqlite"
fi

case "$MODE" in
  auto)
    if [[ -n "$REPO" && -n "$SESSION" ]]; then
      MODE="fs"
    else
      MODE="db"
    fi
    ;;
  db|fs) ;;
  *)
    echo "--mode must be auto|db|fs" >&2
    exit 1
    ;;
esac

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

cmd="$1"
shift

require_db() {
  if [[ -z "$DB" ]]; then
    echo "TEAM_DB not set and --db not provided" >&2
    exit 1
  fi
}

require_fs() {
  if [[ -z "$REPO" || -z "$SESSION" ]]; then
    echo "--repo and --session are required for filesystem mode" >&2
    exit 1
  fi
}

case "$cmd" in
  register)
    if [[ $# -lt 1 ]]; then
      usage
      exit 1
    fi
    require_db
    agent="$1"
    role="${2:-member}"
    python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "$agent" --role "$role"
    ;;

  members)
    if [[ "$MODE" == "fs" ]]; then
      require_fs
      raw="$(python3 "$FS" team-get --repo "$REPO" --session "$SESSION" --json)"
      if [[ "${1:-}" == "--json" ]]; then
        python3 - <<PY
import json
cfg = json.loads('''$raw''')
out=[]
for m in cfg.get("members", []):
    if isinstance(m, dict):
        out.append({
            "agent": m.get("name", ""),
            "agent_id": m.get("agentId", ""),
            "role": m.get("agentType", "member"),
            "mode": m.get("mode", "auto"),
            "backend": m.get("backendType", ""),
            "color": m.get("color", ""),
        })
print(json.dumps(out, ensure_ascii=False))
PY
      else
        python3 - <<PY
import json
cfg = json.loads('''$raw''')
name = cfg.get("name", "")
members = [m for m in cfg.get("members", []) if isinstance(m, dict)]
print(f"team={name}")
print(f"members={len(members)}")
for m in members:
    print(f"agent={m.get('name','')} role={m.get('agentType','member')} mode={m.get('mode','auto')} backend={m.get('backendType','')}")
PY
      fi
    else
      require_db
      args=(--db "$DB" members --room "$ROOM")
      if [[ "${1:-}" == "--json" ]]; then
        args+=(--json)
      fi
      python3 "$BUS" "${args[@]}"
    fi
    ;;

  inbox)
    if [[ $# -lt 1 ]]; then
      usage
      exit 1
    fi
    agent="$1"
    shift

    unread="false"
    mark_read="false"
    json_out="false"
    limit="100"

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --unread) unread="true"; shift ;;
        --mark-read) mark_read="true"; shift ;;
        --json) json_out="true"; shift ;;
        --limit) limit="$2"; shift 2 ;;
        --since-mailbox-id) shift 2 ;; # db-only compat noop in fs mode
        *) echo "Unknown arg for inbox: $1" >&2; exit 1 ;;
      esac
    done

    if [[ "$MODE" == "fs" ]]; then
      require_fs
      args=(mailbox-read --repo "$REPO" --session "$SESSION" --agent "$agent" --limit "$limit")
      [[ "$unread" == "true" ]] && args+=(--unread)
      [[ "$json_out" == "true" ]] && args+=(--json)
      python3 "$FS" "${args[@]}"
      if [[ "$mark_read" == "true" ]]; then
        mark_source_args=(mailbox-read --repo "$REPO" --session "$SESSION" --agent "$agent" --json --limit "$limit")
        [[ "$unread" == "true" ]] && mark_source_args+=(--unread)
        raw_json="$(python3 "$FS" "${mark_source_args[@]}")"
        mapfile -t mark_indexes < <(python3 - "$raw_json" <<'PY'
import json
import sys

raw = sys.argv[1]
if not raw.strip():
    raise SystemExit(0)
try:
    rows = json.loads(raw)
except json.JSONDecodeError:
    raise SystemExit(0)
if not isinstance(rows, list):
    raise SystemExit(0)
for row in rows:
    if not isinstance(row, dict):
        continue
    idx = row.get("index")
    if isinstance(idx, int) and idx >= 0:
        print(idx)
PY
)
        if [[ "${#mark_indexes[@]}" -gt 0 ]]; then
          mark_args=(mailbox-mark-read --repo "$REPO" --session "$SESSION" --agent "$agent")
          for idx in "${mark_indexes[@]}"; do
            mark_args+=(--index "$idx")
          done
          python3 "$FS" "${mark_args[@]}" >/dev/null
        fi
        if [[ "$json_out" != "true" ]]; then
          echo "marked_read=${#mark_indexes[@]}"
        fi
      fi
    else
      require_db
      args=(--db "$DB" inbox --room "$ROOM" --agent "$agent" --limit "$limit")
      [[ "$unread" == "true" ]] && args+=(--unread)
      [[ "$mark_read" == "true" ]] && args+=(--mark-read)
      [[ "$json_out" == "true" ]] && args+=(--json)
      python3 "$BUS" "${args[@]}"
    fi
    ;;

  mark-read)
    if [[ $# -lt 1 ]]; then
      usage
      exit 1
    fi
    agent="$1"
    shift

    all="false"
    ids=()
    up_to=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --all) all="true"; shift ;;
        --up-to) up_to="$2"; shift 2 ;;
        --id) ids+=("$2"); shift 2 ;;
        *) echo "Unknown arg for mark-read: $1" >&2; exit 1 ;;
      esac
    done

    if [[ "$MODE" == "fs" ]]; then
      require_fs
      args=(mailbox-mark-read --repo "$REPO" --session "$SESSION" --agent "$agent")
      if [[ "$all" == "true" ]]; then
        args+=(--all)
      elif [[ -n "$up_to" ]]; then
        raw_json="$(python3 "$FS" mailbox-read --repo "$REPO" --session "$SESSION" --agent "$agent" --json --limit 1000000)"
        mapfile -t up_indexes < <(python3 - "$raw_json" "$up_to" <<'PY'
import json
import sys

raw = sys.argv[1]
up_to = int(sys.argv[2])
if not raw.strip():
    raise SystemExit(0)
try:
    rows = json.loads(raw)
except json.JSONDecodeError:
    raise SystemExit(0)
if not isinstance(rows, list):
    raise SystemExit(0)
for row in rows:
    if not isinstance(row, dict):
        continue
    idx = row.get("index")
    if isinstance(idx, int) and 0 <= idx <= up_to:
        print(idx)
PY
)
        for idx in "${up_indexes[@]}"; do
          args+=(--index "$idx")
        done
      else
        for id in "${ids[@]}"; do
          args+=(--index "$id")
        done
      fi
      python3 "$FS" "${args[@]}"
    else
      require_db
      args=(--db "$DB" mark-read --room "$ROOM" --agent "$agent")
      if [[ "$all" == "true" ]]; then
        args+=(--all)
      elif [[ -n "$up_to" ]]; then
        args+=(--up-to "$up_to")
      else
        for id in "${ids[@]}"; do
          args+=(--id "$id")
        done
      fi
      python3 "$BUS" "${args[@]}"
    fi
    ;;

  pending)
    if [[ $# -lt 1 ]]; then
      usage
      exit 1
    fi
    agent="$1"
    shift

    all_status="false"
    json_out="false"
    limit="100"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --all-status) all_status="true"; shift ;;
        --json) json_out="true"; shift ;;
        --limit) limit="$2"; shift 2 ;;
        *) echo "Unknown arg for pending: $1" >&2; exit 1 ;;
      esac
    done

    if [[ "$MODE" == "fs" ]]; then
      require_fs
      args=(control-pending --repo "$REPO" --session "$SESSION" --agent "$agent" --limit "$limit")
      [[ "$all_status" == "true" ]] && args+=(--all-status)
      [[ "$json_out" == "true" ]] && args+=(--json)
      python3 "$FS" "${args[@]}"
    else
      require_db
      args=(--db "$DB" control-pending --room "$ROOM" --agent "$agent" --limit "$limit")
      [[ "$all_status" == "true" ]] && args+=(--all-status)
      [[ "$json_out" == "true" ]] && args+=(--json)
      python3 "$BUS" "${args[@]}"
    fi
    ;;

  *)
    usage
    exit 1
    ;;
esac
