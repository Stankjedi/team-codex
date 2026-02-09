#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"
TAIL="$SCRIPT_DIR/team_tail.sh"
STATUS="$SCRIPT_DIR/team_status.sh"
MAILBOX="$SCRIPT_DIR/team_mailbox.sh"
CONTROL="$SCRIPT_DIR/team_control.sh"
MODEL_RESOLVER="$SCRIPT_DIR/resolve_model.py"
DASHBOARD_SCRIPT="$SCRIPT_DIR/team_dashboard.sh"
PULSE_SCRIPT="$SCRIPT_DIR/team_pulse.sh"

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
PULSE_WINDOW="team-pulse"

MODEL=""
DIRECTOR_MODEL=""
WORKER_MODEL=""
DIRECTOR_PROFILE_OVERRIDE=""
WORKER_PROFILE_OVERRIDE=""
SESSION_OVERRIDE=""

usage() {
  cat <<'EOF'
Codex Teams orchestrator bridge.

Usage:
  team_codex_ma.sh <init|run|up|status|merge> [options]

Common options:
  --repo PATH               Target repo path (default: current directory)
  --config PATH             backend config path (default: <repo>/.codex-multi-agent.config.sh)
  --room NAME               Team bus room (default: main)

run/up options:
  --task TEXT               Initial task (required for run)
  --workers N               Worker count override (fixed policy: only `3` is accepted)
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
  (auto) launches team-pulse window for worker heartbeat status
  --no-attach               Do not attach tmux after launch

Examples:
  team_codex_ma.sh init
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
  init|run|up|status|merge) ;;
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
  echo "Required backend command not found: codex-ma" >&2
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

if [[ "$COMMAND" != "init" ]]; then
  if [[ -z "$CONFIG" ]]; then
    CONFIG="$REPO/.codex-multi-agent.config.sh"
  else
    CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
  fi

  if [[ ! -f "$CONFIG" ]]; then
    echo "Config file not found: $CONFIG" >&2
    echo "Run: codex-teams init --repo $REPO" >&2
    exit 2
  fi
fi

# Defaults for worker orchestration, then load project config.
COUNT="3"
PREFIX="pair"
TMUX_SESSION="codex-fleet"
DIRECTOR_PROFILE="director"
WORKER_PROFILE="pair"
if [[ "$COMMAND" == "init" ]]; then
  codex-ma init --repo "$REPO"
  echo "Initialized team config at: $REPO/.codex-multi-agent.config.sh"
  exit 0
fi

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
  if [[ "$WORKERS" != "3" ]]; then
    echo "--workers is fixed at 3 in codex-teams bridge mode" >&2
    exit 2
  fi
  COUNT="3"
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

register_team_members() {
  python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "system" --role "system" >/dev/null
  python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "orchestrator" --role "orchestrator" >/dev/null
  python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "monitor" --role "monitor" >/dev/null
  python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "director" --role "director" >/dev/null
  for i in $(seq 1 "$COUNT"); do
    python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "$PREFIX-$i" --role "worker" >/dev/null
  done
}

CONFIG_TO_USE="$CONFIG"
if [[ "$COUNT" != "3" ]]; then
  echo "info: fixed worker policy active (forcing COUNT=3; resolved: $COUNT)" >&2
  COUNT="3"
fi

register_team_members

WRAPPER="$TEAM_ROOT/codex-model-wrapper.sh"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail

BUS_SCRIPT="$BUS"
DB_PATH="$DB"
ROOM_NAME="$ROOM"
DIRECTOR_PROFILE_VALUE="$DIRECTOR_PROFILE"
WORKER_PROFILE_VALUE="$WORKER_PROFILE"
WORKER_PREFIX_VALUE="$PREFIX"
DIRECTOR_MODEL_VALUE="$DIRECTOR_MODEL"
WORKER_MODEL_VALUE="$WORKER_MODEL"
DEFAULT_MODEL_VALUE="$MODEL"

role_profile=""
agent_cwd=""
agent_name="agent"
agent_role="worker"
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
  if [[ "\${args[i]}" == "-p" || "\${args[i]}" == "--profile" ]]; then
    if (( i + 1 < \${#args[@]} )); then
      role_profile="\${args[i+1]}"
    fi
  fi
  if [[ "\${args[i]}" == "-C" || "\${args[i]}" == "--cd" ]]; then
    if (( i + 1 < \${#args[@]} )); then
      agent_cwd="\${args[i+1]}"
    fi
  fi
done

if [[ -z "\$agent_cwd" ]]; then
  agent_cwd="\$(pwd)"
fi
base_name="\$(basename "\$agent_cwd")"

if [[ "\$role_profile" == "\$DIRECTOR_PROFILE_VALUE" ]]; then
  agent_name="director"
  agent_role="director"
elif [[ "\$role_profile" == "\$WORKER_PROFILE_VALUE" ]]; then
  if [[ "\$base_name" =~ ^\${WORKER_PREFIX_VALUE}-[0-9]+$ ]]; then
    agent_name="\$base_name"
  else
    agent_name="\${WORKER_PREFIX_VALUE}-worker"
  fi
  agent_role="worker"
fi

notify_status() {
  local body="\$1"
  python3 "\$BUS_SCRIPT" --db "\$DB_PATH" register --room "\$ROOM_NAME" --agent "\$agent_name" --role "\$agent_role" >/dev/null 2>&1 || true
  python3 "\$BUS_SCRIPT" --db "\$DB_PATH" send --room "\$ROOM_NAME" --from "\$agent_name" --to all --kind status --body "\$body" >/dev/null 2>&1 || true
}

notify_status "online profile=\${role_profile:-default} cwd=\$agent_cwd pid=\$\$"

cmd=(codex)
if [[ "\$role_profile" == "\$DIRECTOR_PROFILE_VALUE" && -n "\$DIRECTOR_MODEL_VALUE" ]]; then
  cmd+=(-m "\$DIRECTOR_MODEL_VALUE")
elif [[ "\$role_profile" == "\$WORKER_PROFILE_VALUE" && -n "\$WORKER_MODEL_VALUE" ]]; then
  cmd+=(-m "\$WORKER_MODEL_VALUE")
elif [[ -n "\$DEFAULT_MODEL_VALUE" ]]; then
  cmd+=(-m "\$DEFAULT_MODEL_VALUE")
fi

set +e
"\${cmd[@]}" "\${args[@]}"
exit_code=\$?
set -e

notify_status "offline exit=\$exit_code cwd=\$agent_cwd"
exit "\$exit_code"
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

run_backend() {
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

resolve_session_repo_from_tmux() {
  local session="$1"
  local pane_path
  while IFS= read -r pane_path; do
    [[ -z "$pane_path" ]] && continue
    if command -v git >/dev/null 2>&1 && git -C "$pane_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      local common_dir
      common_dir="$(git -C "$pane_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
      if [[ -n "$common_dir" ]]; then
        local common_root
        common_root="$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd || true)"
        if [[ -n "$common_root" ]]; then
          printf '%s\n' "$common_root"
          return 0
        fi
      fi
    fi
  done < <(tmux list-panes -s -t "$session" -F "#{pane_current_path}" 2>/dev/null || true)
  return 1
}

guard_session_repo_mismatch() {
  local session="$1"
  local expected_repo="$2"
  if ! tmux has-session -t "$session" >/dev/null 2>&1; then
    return 0
  fi
  local actual_repo
  actual_repo="$(resolve_session_repo_from_tmux "$session" || true)"
  if [[ -n "$actual_repo" && "$actual_repo" != "$expected_repo" ]]; then
    echo "tmux session '$session' is already bound to another repo:" >&2
    echo "- session repo: $actual_repo" >&2
    echo "- requested repo: $expected_repo" >&2
    echo "Use --session <new-name> or terminate old session (tmux kill-session -t $session)." >&2
    exit 2
  fi
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

launch_pulse_window() {
  local session="$1"
  if [[ ! -x "$PULSE_SCRIPT" ]]; then
    echo "pulse script is not executable: $PULSE_SCRIPT" >&2
    return 1
  fi

  if window_exists "$session" "$PULSE_WINDOW"; then
    tmux send-keys -t "$session:$PULSE_WINDOW" C-c >/dev/null 2>&1 || true
  else
    tmux new-window -t "$session" -n "$PULSE_WINDOW" -c "$REPO"
  fi

  tmux send-keys -t "$session:$PULSE_WINDOW" \
    "TEAM_DB='$DB' '$PULSE_SCRIPT' --session '$session' --room '$ROOM' --prefix '$PREFIX' --count '$COUNT'" C-m
}

case "$COMMAND" in
  run|up)
    guard_session_repo_mismatch "$TMUX_SESSION" "$REPO"
    run_backend "$COMMAND"
    attach_bus_windows "$TMUX_SESSION"
    launch_dashboard_window "$TMUX_SESSION"
    launch_pulse_window "$TMUX_SESSION"

    python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind system \
      --body "session=$TMUX_SESSION started via codex-teams workers=$COUNT"

    if [[ -n "$TASK" ]]; then
      python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to director --kind task --body "$TASK"
    fi
    python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind system \
      --body "protocol: use team_send.sh for status/blocker updates, team_mailbox.sh inbox for unread, team_control.sh for approval/shutdown/permission requests"

    echo "Bridge session ready"
    echo "- repo: $REPO"
    echo "- tmux session: $TMUX_SESSION"
    echo "- room: $ROOM"
    echo "- bus db: $DB"
    echo "- workers: $COUNT (fixed)"
    if [[ -n "$DIRECTOR_MODEL" || -n "$WORKER_MODEL" ]]; then
      echo "- models: director=${DIRECTOR_MODEL:-<config default>} worker=${WORKER_MODEL:-<config default>}"
    fi
    echo "- status: TEAM_DB='$DB' '$STATUS' --room '$ROOM'"
    echo "- inbox: TEAM_DB='$DB' '$MAILBOX' inbox <agent> --unread"
    echo "- control: TEAM_DB='$DB' '$CONTROL' request --type plan_approval <from> <to> <body>"
    if [[ "$DASHBOARD" == "true" ]]; then
      echo "- dashboard window: $DASHBOARD_WINDOW"
      echo "- dashboard cmd: TEAM_DB='$DB' '$DASHBOARD_SCRIPT' --session '$TMUX_SESSION' --repo '$REPO' --room '$ROOM'"
    fi
    echo "- pulse window: $PULSE_WINDOW"
    echo "- pulse cmd: TEAM_DB='$DB' '$PULSE_SCRIPT' --session '$TMUX_SESSION' --room '$ROOM' --prefix '$PREFIX' --count '$COUNT'"

    if [[ "$NO_ATTACH" != "true" ]]; then
      tmux attach -t "$TMUX_SESSION"
    fi
    ;;
  status)
    run_backend status
    if [[ -f "$DB" ]]; then
      TEAM_DB="$DB" "$STATUS" --room "$ROOM"
    else
      echo "team bus not initialized yet: $DB"
    fi
    ;;
  merge)
    run_backend merge
    if [[ -f "$DB" ]]; then
      python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind status --body "merge completed"
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac
