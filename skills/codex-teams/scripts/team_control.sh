#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"
FS="$SCRIPT_DIR/team_fs.py"

DB="${TEAM_DB:-}"
ROOM="main"
REPO=""
SESSION=""

validate_session_name() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    echo "session is required" >&2
    exit 1
  fi
  if [[ "$raw" == *"/"* || "$raw" == *"\\"* ]]; then
    echo "invalid session name '$raw' (path separators are not allowed)" >&2
    exit 1
  fi
  if [[ "$raw" == "." || "$raw" == ".." || "$raw" == *".."* ]]; then
    echo "invalid session name '$raw'" >&2
    exit 1
  fi
  if ! [[ "$raw" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "invalid session name '$raw' (allowed: [A-Za-z0-9._-], max 128, starts with alnum)" >&2
    exit 1
  fi
  printf '%s\n' "$raw"
}

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
if [[ -n "$SESSION" ]]; then
  SESSION="$(validate_session_name "$SESSION")"
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
    request_printed="false"
    fs_persisted="false"
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
      fs_persisted="true"
    fi
    if [[ -n "$DB" ]]; then
      if out="$(python3 "$BUS" --db "$DB" control-request --room "$ROOM" --type "$req_type" --from "$sender" --to "$recipient" --body "$body" --summary "$summary" --request-id "$request_id" 2>/dev/null)"; then
        if [[ -n "$out" ]]; then
          printf '%s\n' "$out"
          request_printed="true"
        fi
      elif [[ "$fs_persisted" == "true" ]]; then
        echo "warn: bus control request persistence failed request_id=$request_id type=$req_type (fs persisted)" >&2
      else
        echo "failed to persist control request to db" >&2
        exit 1
      fi
    fi

    if [[ "$request_printed" != "true" ]]; then
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
    req_sender=""
    if [[ -n "$DB" ]]; then
      if [[ "$decision" == "approve" ]]; then
        bus_args=(--db "$DB" control-respond --request-id "$req_id" --from "$sender" --approve --body "$body")
      else
        bus_args=(--db "$DB" control-respond --request-id "$req_id" --from "$sender" --reject --body "$body")
      fi
      if out="$(python3 "$BUS" "${bus_args[@]}" 2>/dev/null)"; then
        printf '%s\n' "$out"
      elif [[ -n "$REPO" && -n "$SESSION" ]]; then
        echo "warn: bus control response persistence failed request_id=$req_id (fs fallback)" >&2
      else
        echo "failed to persist control response to db" >&2
        exit 1
      fi

      req_type_lookup=""
      if req_type_lookup="$(python3 - "$DB" "$req_id" 2>/dev/null <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
row = conn.execute('select req_type from control_requests where request_id=?', (sys.argv[2],)).fetchone()
print(row[0] if row else "")
PY
      )"; then
        req_type="$req_type_lookup"
      fi
      pair_lookup=""
      if pair_lookup="$(python3 - "$DB" "$req_id" 2>/dev/null <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
row = conn.execute('select sender, recipient from control_requests where request_id=?', (sys.argv[2],)).fetchone()
if row:
    print(f"{row[0]}|{row[1]}")
else:
    print("|")
PY
      )"; then
        req_sender="${pair_lookup%%|*}"
      fi
    fi

    if [[ -n "$REPO" && -n "$SESSION" ]]; then
      if [[ -z "$req_type" || -z "$req_sender" ]]; then
        fs_fields="$(python3 - "$FS" "$REPO" "$SESSION" "$req_id" <<'PY'
import json
import subprocess
import sys

fs, repo, session, request_id = sys.argv[1:5]
proc = subprocess.run(
    [sys.executable, fs, "control-get", "--repo", repo, "--session", session, "--request-id", request_id, "--json"],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    check=False,
)
if proc.returncode != 0 or not proc.stdout.strip():
    print("|")
    raise SystemExit(0)
try:
    req = json.loads(proc.stdout)
except json.JSONDecodeError:
    print("|")
    raise SystemExit(0)
print(f"{req.get('req_type','')}|{req.get('sender','')}")
PY
)"
        if [[ -n "$fs_fields" && "$fs_fields" != "|" ]]; then
          [[ -z "$req_type" ]] && req_type="${fs_fields%%|*}"
          [[ -z "$req_sender" ]] && req_sender="${fs_fields##*|}"
        fi
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
