#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"
FS="$SCRIPT_DIR/team_fs.py"

DB="${TEAM_DB:-}"
ROOM="main"
REPO=""
SESSION=""

usage() {
  cat <<'EOF'
Usage:
  team_control.sh [--db PATH] [--room NAME] [--repo PATH --session NAME] request --type <plan_approval|shutdown|permission|mode_set> <from> <to> [message...]
  team_control.sh [--db PATH] [--room NAME] [--repo PATH --session NAME] respond --request-id ID --approve|--reject <from> [--to RECIPIENT] [message...]

Examples:
  TEAM_DB=.codex-teams/codex-fleet/bus.sqlite team_control.sh request --type plan_approval worker-1 lead "ready for review" --summary "task-04"
  team_control.sh --repo . --session codex-fleet respond --request-id abc123 --approve lead --to worker-1 "approved"
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

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

cmd="$1"
shift

case "$cmd" in
  request)
    req_type=""
    summary=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --type)
          req_type="$2"
          shift 2
          ;;
        --summary)
          summary="$2"
          shift 2
          ;;
        *)
          break
          ;;
      esac
    done

    if [[ -z "$req_type" || $# -lt 2 ]]; then
      usage
      exit 1
    fi

    sender="$1"
    recipient="$2"
    shift 2
    body="$*"
    if [[ -z "$body" ]]; then
      body="${req_type} request"
    fi

    request_id="$(python3 - <<'PY'
import uuid
print(uuid.uuid4().hex[:12])
PY
)"
    if [[ -n "$DB" ]]; then
      out="$(python3 "$BUS" --db "$DB" control-request --room "$ROOM" --type "$req_type" --from "$sender" --to "$recipient" --body "$body" --summary "$summary" --request-id "$request_id")"
      printf '%s\n' "$out"
    fi

    if [[ -n "$REPO" && -n "$SESSION" ]]; then
      python3 "$FS" control-request \
        --repo "$REPO" \
        --session "$SESSION" \
        --type "$req_type" \
        --from "$sender" \
        --to "$recipient" \
        --body "$body" \
        --summary "$summary" \
        --request-id "$request_id" >/dev/null
    fi

    if [[ -z "$DB" ]]; then
      echo "request_id=$request_id"
    fi
    ;;

  respond)
    req_id=""
    decision=""
    recipient=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --request-id)
          req_id="$2"
          shift 2
          ;;
        --approve)
          decision="approve"
          shift
          ;;
        --reject)
          decision="reject"
          shift
          ;;
        --to)
          recipient="$2"
          shift 2
          ;;
        *)
          break
          ;;
      esac
    done

    if [[ -z "$req_id" || -z "$decision" || $# -lt 1 ]]; then
      usage
      exit 1
    fi

    sender="$1"
    shift
    body="$*"
    [[ -z "$body" ]] && body="$decision"

    req_type=""
    if [[ -n "$DB" ]]; then
      if [[ "$decision" == "approve" ]]; then
        out="$(python3 "$BUS" --db "$DB" control-respond --request-id "$req_id" --from "$sender" --approve --body "$body")"
      else
        out="$(python3 "$BUS" --db "$DB" control-respond --request-id "$req_id" --from "$sender" --reject --body "$body")"
      fi
      printf '%s\n' "$out"

      req_type="$(python3 - "$DB" "$req_id" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
row = conn.execute('select req_type from control_requests where request_id=?', (sys.argv[2],)).fetchone()
print(row[0] if row else "")
PY
)"
    fi

    if [[ -n "$REPO" && -n "$SESSION" ]]; then
      req_sender=""
      if [[ -n "$DB" ]]; then
        pair="$(python3 - "$DB" "$req_id" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
row = conn.execute('select sender, recipient from control_requests where request_id=?', (sys.argv[2],)).fetchone()
if row:
    print(f"{row[0]}|{row[1]}")
else:
    print("|")
PY
)"
        req_sender="${pair%%|*}"
      fi
      approve_flag="false"
      [[ "$decision" == "approve" ]] && approve_flag="true"
      args=(control-respond \
        --repo "$REPO" \
        --session "$SESSION" \
        --request-id "$req_id" \
        --from "$sender" \
        --body "$body")
      if [[ "$approve_flag" == "true" ]]; then
        args+=(--approve)
      else
        args+=(--reject)
      fi
      if [[ -n "$recipient" ]]; then
        args+=(--to "$recipient")
      elif [[ -n "$req_sender" ]]; then
        args+=(--to "$req_sender")
      fi
      if [[ -n "$req_type" ]]; then
        args+=(--req-type "$req_type")
      fi
      python3 "$FS" "${args[@]}" >/dev/null
    fi
    ;;

  *)
    usage
    exit 1
    ;;
esac
