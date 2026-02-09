#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"

DB="${TEAM_DB:-}"
ROOM="main"
AGENT="monitor"
ALL="false"
JSON="false"
SINCE_ID="0"
POLL_MS="800"

usage() {
  cat <<'EOF'
Usage:
  team_tail.sh [--db PATH] [--room NAME] [--since-id N] [--poll-ms N] [--all] [--json] [agent]

Examples:
  TEAM_DB=.codex-teams/bus.sqlite team_tail.sh director
  team_tail.sh --db /tmp/bus.sqlite --all monitor
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
    --since-id)
      SINCE_ID="$2"
      shift 2
      ;;
    --poll-ms)
      POLL_MS="$2"
      shift 2
      ;;
    --all)
      ALL="true"
      shift
      ;;
    --json)
      JSON="true"
      shift
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
      AGENT="$1"
      shift
      ;;
  esac
done

if [[ -z "$DB" ]]; then
  echo "TEAM_DB not set and --db not provided" >&2
  exit 1
fi

args=(
  --db "$DB"
  tail
  --room "$ROOM"
  --agent "$AGENT"
  --since-id "$SINCE_ID"
  --poll-ms "$POLL_MS"
  --follow
)

if [[ "$ALL" == "true" ]]; then
  args+=(--all)
fi
if [[ "$JSON" == "true" ]]; then
  args+=(--json)
fi

python3 "$BUS" "${args[@]}"
