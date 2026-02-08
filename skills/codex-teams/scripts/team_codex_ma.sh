#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"
TAIL="$SCRIPT_DIR/team_tail.sh"
STATUS="$SCRIPT_DIR/team_status.sh"
MODEL_RESOLVER="$SCRIPT_DIR/resolve_model.py"
DASHBOARD_SCRIPT="$SCRIPT_DIR/team_dashboard.sh"

COMMAND=""
REPO="$(pwd)"
CONFIG=""
TASK=""
ROOM="main"
WORKERS=""
NO_ATTACH="false"
DASHBOARD="false"
DASHBOARD_WINDOW="team-dashboard"
DASHBOARD_LINES="18"
DASHBOARD_MESSAGES="24"

MODEL=""
DIRECTOR_MODEL=""
WORKER_MODEL=""
DIRECTOR_PROFILE_OVERRIDE=""
WORKER_PROFILE_OVERRIDE=""
SESSION_OVERRIDE=""
AUTO_WORKERS_APPLIED="false"
AUTO_WORKERS_REASON=""

usage() {
  cat <<'EOF'
Codex Teams + codex-ma bridge.

Usage:
  team_codex_ma.sh <run|up|status|merge> [options]

Common options:
  --repo PATH               Target repo path (default: current directory)
  --config PATH             codex-ma config path (default: <repo>/.codex-multi-agent.config.sh)
  --room NAME               Team bus room (default: main)

run/up options:
  --task TEXT               Initial task (required for run)
  --workers N               Override worker count for codex-ma (disables auto orchestration)
  --model MODEL             Override model for all roles
  --director-model MODEL    Override director model only
  --worker-model MODEL      Override worker model only
  --director-profile NAME   Resolve director model using this profile
  --worker-profile NAME     Resolve worker model using this profile
  --session NAME            Override tmux session name
  --dashboard               Launch live dashboard view automatically
  --dashboard-window NAME   tmux window name for dashboard (default: team-dashboard)
  --dashboard-lines N       Capture lines per pane in dashboard (default: 18)
  --dashboard-messages N    Recent bus messages in dashboard (default: 24)
  --no-attach               Do not attach tmux after launch

Examples:
  team_codex_ma.sh run --task "Implement task pack" --workers 3
  team_codex_ma.sh run --task "Fix CI" --model gpt-5.3-codex
  team_codex_ma.sh status
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

COMMAND="$1"
shift

case "$COMMAND" in
  run|up|status|merge) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unsupported command: $COMMAND" >&2
    usage
    exit 2
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --config)
      CONFIG="$2"
      shift 2
      ;;
    --task)
      TASK="$2"
      shift 2
      ;;
    --room)
      ROOM="$2"
      shift 2
      ;;
    --workers)
      WORKERS="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --director-model)
      DIRECTOR_MODEL="$2"
      shift 2
      ;;
    --worker-model)
      WORKER_MODEL="$2"
      shift 2
      ;;
    --director-profile)
      DIRECTOR_PROFILE_OVERRIDE="$2"
      shift 2
      ;;
    --worker-profile)
      WORKER_PROFILE_OVERRIDE="$2"
      shift 2
      ;;
    --session)
      SESSION_OVERRIDE="$2"
      shift 2
      ;;
    --dashboard)
      DASHBOARD="true"
      shift
      ;;
    --dashboard-window)
      DASHBOARD_WINDOW="$2"
      shift 2
      ;;
    --dashboard-lines)
      DASHBOARD_LINES="$2"
      shift 2
      ;;
    --dashboard-messages)
      DASHBOARD_MESSAGES="$2"
      shift 2
      ;;
    --no-attach)
      NO_ATTACH="true"
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

if ! command -v codex-ma >/dev/null 2>&1; then
  echo "codex-ma command not found in PATH" >&2
  exit 2
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 2
fi

if ! [[ "$DASHBOARD_LINES" =~ ^[0-9]+$ ]] || [[ "$DASHBOARD_LINES" -lt 1 ]]; then
  echo "--dashboard-lines must be an integer >= 1" >&2
  exit 2
fi
if ! [[ "$DASHBOARD_MESSAGES" =~ ^[0-9]+$ ]] || [[ "$DASHBOARD_MESSAGES" -lt 1 ]]; then
  echo "--dashboard-messages must be an integer >= 1" >&2
  exit 2
fi

REPO="$(cd "$REPO" && pwd)"
if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not a git repository: $REPO" >&2
  exit 2
fi
REPO="$(git -C "$REPO" rev-parse --show-toplevel)"

if [[ -z "$CONFIG" ]]; then
  CONFIG="$REPO/.codex-multi-agent.config.sh"
else
  CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "Config file not found: $CONFIG" >&2
  echo "Run: codex-ma init --repo $REPO" >&2
  exit 2
fi

# Orchestrator heuristic that auto-scales pair workers from 2..4 based on task scope.
orchestrator_pick_worker_count() {
  local raw_task="$1"
  local task
  task="$(printf '%s' "$raw_task" | tr '[:upper:]' '[:lower:]')"
  local words
  words="$(printf '%s\n' "$task" | wc -w | tr -d ' ')"
  local score=0
  local domain_count=0
  local separators=0
  local reasons=()

  if [[ "$words" -ge 35 ]]; then
    score=$((score + 1))
    reasons+=("long-brief")
  fi
  if [[ "$words" -ge 80 ]]; then
    score=$((score + 1))
    reasons+=("very-long-brief")
  fi

  [[ "$task" == *","* ]] && separators=$((separators + 1))
  [[ "$task" == *";"* ]] && separators=$((separators + 1))
  [[ "$task" == *$'\n'* ]] && separators=$((separators + 1))
  [[ "$task" =~ [0-9]+\.[[:space:]] ]] && separators=$((separators + 1))
  [[ "$task" == *" and "* ]] && separators=$((separators + 1))
  if [[ "$separators" -ge 2 ]]; then
    score=$((score + 1))
    reasons+=("multi-subtasks")
  fi

  [[ "$task" =~ (ui|ux|frontend|react|vue|css|design|layout) ]] && domain_count=$((domain_count + 1))
  [[ "$task" =~ (backend|server|api|endpoint|controller|service) ]] && domain_count=$((domain_count + 1))
  [[ "$task" =~ (db|database|sql|schema|migration|postgres|mysql|sqlite|redis) ]] && domain_count=$((domain_count + 1))
  [[ "$task" =~ (test|testing|ci|e2e|integration|unit) ]] && domain_count=$((domain_count + 1))
  [[ "$task" =~ (deploy|docker|k8s|infra|terraform|pipeline|release) ]] && domain_count=$((domain_count + 1))
  [[ "$task" =~ (docs|readme|documentation) ]] && domain_count=$((domain_count + 1))
  if [[ "$domain_count" -ge 3 ]]; then
    score=$((score + 1))
    reasons+=("cross-domain")
  fi
  if [[ "$domain_count" -ge 5 ]]; then
    score=$((score + 1))
    reasons+=("wide-scope")
  fi

  if [[ "$task" =~ (refactor|migration|re-architect|rearchitect|rewrite|major|end-to-end|across) ]]; then
    score=$((score + 1))
    reasons+=("complex-change")
  fi

  local picked="2"
  if [[ "$score" -ge 4 ]]; then
    picked="4"
  elif [[ "$score" -ge 2 ]]; then
    picked="3"
  fi

  local reason="baseline"
  if [[ "${#reasons[@]}" -gt 0 ]]; then
    reason="$(IFS=,; echo "${reasons[*]}")"
  fi

  printf '%s|%s\n' "$picked" "$reason"
}

# Defaults aligned with codex-ma, then load project config.
COUNT="4"
PREFIX="pair"
TMUX_SESSION="codex-fleet"
DIRECTOR_PROFILE="director"
WORKER_PROFILE="pair"
# shellcheck source=/dev/null
source "$CONFIG"

if [[ -n "$DIRECTOR_PROFILE_OVERRIDE" ]]; then
  DIRECTOR_PROFILE="$DIRECTOR_PROFILE_OVERRIDE"
fi
if [[ -n "$WORKER_PROFILE_OVERRIDE" ]]; then
  WORKER_PROFILE="$WORKER_PROFILE_OVERRIDE"
fi
if [[ -n "$SESSION_OVERRIDE" ]]; then
  TMUX_SESSION="$SESSION_OVERRIDE"
fi
if [[ -n "$WORKERS" ]]; then
  if ! [[ "$WORKERS" =~ ^[0-9]+$ ]] || [[ "$WORKERS" -lt 1 ]]; then
    echo "--workers must be an integer >= 1" >&2
    exit 2
  fi
  COUNT="$WORKERS"
elif [[ "$COMMAND" == "run" && -n "$TASK" ]]; then
  orchestrator_decision="$(orchestrator_pick_worker_count "$TASK")"
  COUNT="${orchestrator_decision%%|*}"
  AUTO_WORKERS_REASON="${orchestrator_decision#*|}"
  AUTO_WORKERS_APPLIED="true"
fi

if [[ -n "$MODEL" ]]; then
  DIRECTOR_MODEL="$MODEL"
  WORKER_MODEL="$MODEL"
fi

if [[ -z "$DIRECTOR_MODEL" ]]; then
  DIRECTOR_MODEL="$(python3 "$MODEL_RESOLVER" --project-root "$REPO" --role director --profile "$DIRECTOR_PROFILE" 2>/dev/null || true)"
fi
if [[ -z "$WORKER_MODEL" ]]; then
  WORKER_MODEL="$(python3 "$MODEL_RESOLVER" --project-root "$REPO" --role worker --profile "$WORKER_PROFILE" 2>/dev/null || true)"
fi

TEAM_ROOT="$REPO/.codex-teams/$TMUX_SESSION"
PROMPT_DIR="$TEAM_ROOT/prompts"
DB="$TEAM_ROOT/bus.sqlite"
mkdir -p "$PROMPT_DIR"
python3 "$BUS" --db "$DB" init >/dev/null

CONFIG_TO_USE="$CONFIG"
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
  echo "worker count must be an integer >= 1 (resolved: $COUNT)" >&2
  exit 2
fi

if [[ -n "$DIRECTOR_MODEL" || -n "$WORKER_MODEL" || -n "$SESSION_OVERRIDE" || -n "$WORKERS" || -n "$DIRECTOR_PROFILE_OVERRIDE" || -n "$WORKER_PROFILE_OVERRIDE" || "$AUTO_WORKERS_APPLIED" == "true" ]]; then
  WRAPPER="$TEAM_ROOT/codex-model-wrapper.sh"
  cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
role_profile=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
  if [[ "\${args[i]}" == "-p" || "\${args[i]}" == "--profile" ]]; then
    if (( i + 1 < \${#args[@]} )); then
      role_profile="\${args[i+1]}"
    fi
    break
  fi
done
if [[ "\$role_profile" == "$DIRECTOR_PROFILE" && -n "$DIRECTOR_MODEL" ]]; then
  exec codex -m "$DIRECTOR_MODEL" "\$@"
fi
if [[ "\$role_profile" == "$WORKER_PROFILE" && -n "$WORKER_MODEL" ]]; then
  exec codex -m "$WORKER_MODEL" "\$@"
fi
if [[ -n "$MODEL" ]]; then
  exec codex -m "$MODEL" "\$@"
fi
exec codex "\$@"
EOF
  chmod +x "$WRAPPER"

  CONFIG_TO_USE="$TEAM_ROOT/codex-ma.generated.config.sh"
  cp "$CONFIG" "$CONFIG_TO_USE"
  {
    echo ""
    echo "# codex-teams generated overrides"
    echo "CODEX_BIN=\"$WRAPPER\""
    echo "COUNT=\"$COUNT\""
    echo "TMUX_SESSION=\"$TMUX_SESSION\""
    echo "DIRECTOR_PROFILE=\"$DIRECTOR_PROFILE\""
    echo "WORKER_PROFILE=\"$WORKER_PROFILE\""
  } >> "$CONFIG_TO_USE"
fi

run_codex_ma() {
  local sub="$1"
  shift || true
  case "$sub" in
    run)
      if [[ -z "$TASK" ]]; then
        echo "--task is required for run" >&2
        exit 2
      fi
      codex-ma run --repo "$REPO" --config "$CONFIG_TO_USE" --task "$TASK" </dev/null
      ;;
    up)
      codex-ma up --repo "$REPO" --config "$CONFIG_TO_USE" </dev/null
      ;;
    status)
      codex-ma status --repo "$REPO" --config "$CONFIG_TO_USE"
      ;;
    merge)
      codex-ma merge --repo "$REPO" --config "$CONFIG_TO_USE"
      ;;
    *)
      echo "Unsupported command: $sub" >&2
      exit 2
      ;;
  esac
}

window_exists() {
  local session="$1"
  local window_name="$2"
  tmux list-windows -t "$session" -F "#{window_name}" 2>/dev/null | grep -Fxq "$window_name"
}

ensure_tail_pane() {
  local session="$1"
  local window_name="$2"
  local agent_name="$3"
  local pane_count
  pane_count="$(tmux list-panes -t "$session:$window_name" | wc -l | tr -d ' ')"
  if [[ "$pane_count" -lt 2 ]]; then
    tmux split-window -h -t "$session:$window_name" -c "$REPO"
  fi
  local pane_index
  pane_index="$(tmux list-panes -t "$session:$window_name" -F "#{pane_index}" | tail -n 1)"
  tmux send-keys -t "$session:$window_name.$pane_index" "TEAM_DB='$DB' '$TAIL' --room '$ROOM' '$agent_name'" C-m
}

attach_bus_windows() {
  local session="$1"

  if ! tmux has-session -t "$session" >/dev/null 2>&1; then
    echo "tmux session not found: $session" >&2
    exit 2
  fi

  if ! window_exists "$session" "team-monitor"; then
    tmux new-window -t "$session" -n "team-monitor" -c "$REPO"
  fi
  tmux send-keys -t "$session:team-monitor" "TEAM_DB='$DB' '$TAIL' --room '$ROOM' --all monitor" C-m

  if window_exists "$session" "director"; then
    ensure_tail_pane "$session" "director" "director"
  fi

  for i in $(seq 1 "$COUNT"); do
    local worker_window="$PREFIX-$i"
    if window_exists "$session" "$worker_window"; then
      ensure_tail_pane "$session" "$worker_window" "$worker_window"
    fi
  done
}

launch_dashboard_window() {
  local session="$1"
  if [[ "$DASHBOARD" != "true" ]]; then
    return 0
  fi

  if [[ ! -x "$DASHBOARD_SCRIPT" ]]; then
    echo "dashboard script is not executable: $DASHBOARD_SCRIPT" >&2
    return 1
  fi

  if window_exists "$session" "$DASHBOARD_WINDOW"; then
    tmux send-keys -t "$session:$DASHBOARD_WINDOW" C-c >/dev/null 2>&1 || true
  else
    tmux new-window -t "$session" -n "$DASHBOARD_WINDOW" -c "$REPO"
  fi

  tmux send-keys -t "$session:$DASHBOARD_WINDOW" \
    "TEAM_DB='$DB' '$DASHBOARD_SCRIPT' --session '$session' --repo '$REPO' --room '$ROOM' --lines '$DASHBOARD_LINES' --messages '$DASHBOARD_MESSAGES'" C-m
}

case "$COMMAND" in
  run|up)
    run_codex_ma "$COMMAND"
    attach_bus_windows "$TMUX_SESSION"
    launch_dashboard_window "$TMUX_SESSION"

    python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind system \
      --body "session=$TMUX_SESSION started via codex-ma workers=$COUNT"
    if [[ "$AUTO_WORKERS_APPLIED" == "true" ]]; then
      python3 "$BUS" --db "$DB" send --room "$ROOM" --from orchestrator --to all --kind status \
        --body "auto-worker-scaling selected pairs=$COUNT reason=$AUTO_WORKERS_REASON"
    fi

    if [[ -n "$TASK" ]]; then
      python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to director --kind task --body "$TASK"
    fi

    echo "Bridge session ready"
    echo "- repo: $REPO"
    echo "- tmux session: $TMUX_SESSION"
    echo "- room: $ROOM"
    echo "- bus db: $DB"
    if [[ "$AUTO_WORKERS_APPLIED" == "true" ]]; then
      echo "- workers: $COUNT (orchestrator auto-scaling: $AUTO_WORKERS_REASON)"
    else
      echo "- workers: $COUNT"
    fi
    if [[ -n "$DIRECTOR_MODEL" || -n "$WORKER_MODEL" ]]; then
      echo "- models: director=${DIRECTOR_MODEL:-<config default>} worker=${WORKER_MODEL:-<config default>}"
    fi
    echo "- status: TEAM_DB='$DB' '$STATUS' --room '$ROOM'"
    if [[ "$DASHBOARD" == "true" ]]; then
      echo "- dashboard window: $DASHBOARD_WINDOW"
      echo "- dashboard cmd: TEAM_DB='$DB' '$DASHBOARD_SCRIPT' --session '$TMUX_SESSION' --repo '$REPO' --room '$ROOM'"
    fi

    if [[ "$NO_ATTACH" != "true" ]]; then
      tmux attach -t "$TMUX_SESSION"
    fi
    ;;
  status)
    run_codex_ma status
    if [[ -f "$DB" ]]; then
      TEAM_DB="$DB" "$STATUS" --room "$ROOM"
    else
      echo "team bus not initialized yet: $DB"
    fi
    ;;
  merge)
    run_codex_ma merge
    if [[ -f "$DB" ]]; then
      python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind status --body "merge completed"
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac
