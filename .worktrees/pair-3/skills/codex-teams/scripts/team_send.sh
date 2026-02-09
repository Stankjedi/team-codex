#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"

DB="${TEAM_DB:-}"
ROOM="main"
KIND="note"

usage() {
  cat <<'EOF'
Usage:
  team_send.sh [--db PATH] [--room NAME] [--kind KIND] <from> <to> <message...>

Examples:
  TEAM_DB=.codex-teams/bus.sqlite team_send.sh director worker-1 "Split task A/B"
  team_send.sh --db /tmp/bus.sqlite --kind blocker worker-2 director "Tests failing on ws schema"
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
    --kind)
      KIND="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 3 ]]; then
  usage
  exit 1
fi

if [[ -z "$DB" ]]; then
  echo "TEAM_DB not set and --db not provided" >&2
  exit 1
fi

SENDER="$1"
RECIPIENT="$2"
shift 2
BODY="$*"

python3 "$BUS" --db "$DB" send \
  --room "$ROOM" \
  --from "$SENDER" \
  --to "$RECIPIENT" \
  --kind "$KIND" \
  --body "$BODY"
