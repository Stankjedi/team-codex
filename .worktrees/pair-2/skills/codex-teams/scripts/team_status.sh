#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"

DB="${TEAM_DB:-}"
ROOM="main"

usage() {
  echo "Usage: team_status.sh [--db PATH] [--room NAME]"
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DB" ]]; then
  echo "TEAM_DB not set and --db not provided" >&2
  exit 1
fi

python3 "$BUS" --db "$DB" status --room "$ROOM"
