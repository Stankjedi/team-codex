#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"
FS="$SCRIPT_DIR/team_fs.py"
STATUS="$SCRIPT_DIR/team_status.sh"
MAILBOX="$SCRIPT_DIR/team_mailbox.sh"
CONTROL="$SCRIPT_DIR/team_control.sh"
MODEL_RESOLVER="$SCRIPT_DIR/resolve_model.py"
DASHBOARD_SCRIPT="$SCRIPT_DIR/team_dashboard.sh"
PULSE_SCRIPT="$SCRIPT_DIR/team_pulse.sh"
TAIL_SCRIPT="$SCRIPT_DIR/team_tail.sh"
INPROCESS_AGENT="$SCRIPT_DIR/team_inprocess_agent.py"
INPROCESS_HUB="$SCRIPT_DIR/team_inprocess_hub.py"
TMUX_MAILBOX_BRIDGE="$SCRIPT_DIR/team_tmux_mailbox_bridge.py"
LEGACY_SCRIPT="$SCRIPT_DIR/team_codex_ma.sh"
VIEWER_BRIDGE_FILE=".codex-teams/.viewer-session.json"
WINDOWS_GIT_EXE_PATH="/mnt/c/Program Files/Git/cmd/git.exe"

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
MAILBOX_WINDOW="team-mailbox"
MONITOR_WINDOW="team-monitor"
SWARM_WINDOW="swarm"

MODEL=""
DIRECTOR_MODEL=""
WORKER_MODEL=""
DIRECTOR_PROFILE_OVERRIDE=""
WORKER_PROFILE_OVERRIDE=""
SESSION_OVERRIDE=""

TEAM_NAME_OVERRIDE=""
TEAM_DESCRIPTION=""
TEAMCREATE_REPLACE="false"
DELETE_FORCE="false"

TEAM_LEAD_NAME="lead"
LEAD_AGENT_TYPE="team-lead"
TEAMMATE_MODE="in-process-shared"
TMUX_LAYOUT="split"
PERMISSION_MODE="default"
PLAN_MODE_REQUIRED="false"
TEAMMATE_MODE_OVERRIDE=""
TMUX_LAYOUT_OVERRIDE=""
PERMISSION_MODE_OVERRIDE=""
PLAN_MODE_REQUIRED_OVERRIDE=""
AUTO_DELEGATE="true"
AUTO_DELEGATE_OVERRIDE=""
AUTO_KILL_DONE_WORKER_TMUX="true"

MESSAGE_TYPE="message"
MESSAGE_SENDER=""
MESSAGE_RECIPIENT=""
MESSAGE_CONTENT=""
MESSAGE_SUMMARY=""
MESSAGE_KIND=""
MESSAGE_META="{}"
MESSAGE_REQUEST_ID=""
MESSAGE_APPROVE=""

AUTO_WORKERS_APPLIED="false"
AUTO_WORKERS_REASON=""

LEAD_MODEL=""
LEAD_PROFILE=""
GIT_BIN_OVERRIDE=""
GIT_BIN=""
BOOT_GIT_BIN="git"
UTILITY_PROFILE=""
UTILITY_MODEL=""
WORKER_COUNT="2"
UTILITY_COUNT="1"
TEAM_ROLE_SUMMARY=""
NORMALIZED_TEAMMATE_MODE=""
LEAD_WORKTREE_NAME="lead-1"
LEAD_WORKTREE=""

declare -a TEAM_AGENT_NAMES=()
declare -A TEAM_AGENT_ROLE=()
declare -A TEAM_AGENT_PROFILE=()
declare -A TEAM_AGENT_MODEL=()
declare -A BOOT_PROMPT_BY_AGENT=()

usage() {
  cat <<'USAGE'
Codex Teams (Windows+WSL only, filesystem mailbox + bus + tmux/in-process backends)

Usage:
  team_codex.sh <command> [options]

Commands:
  init                    Initialize codex-ma compatible project config
  setup                   Prepare repository (git init + initial commit) for codex-teams
  run                     TeamCreate + spawn teammates + inject task
  up                      Same as run without task injection
  status                  Show runtime/team/bus/tmux status
  merge                   Merge worker branches (delegates to codex-ma backend)
  teamcreate              Create team config/inboxes/state
  teamdelete              Delete team artifacts
  sendmessage             Send typed team message (Claude Teams-style union)

Platform policy:
  - Windows host + WSL environment only
  - repository path must be under /mnt/<drive>/...
  - fixed team topology: lead + worker-N + utility-1

Common options:
  --repo PATH             Target repo path (default: current directory, supports C:\... auto-convert)
  --config PATH           Config path (default: <repo>/.codex-multi-agent.config.sh, supports C:\... auto-convert)
  --room NAME             Team bus room (default: main)
  --session NAME          Session/team name override
  --workers N|auto        Worker pool size override (`auto`: adaptive 2..4)
  --director-profile NAME Lead profile override (legacy flag name)
  --worker-profile NAME   Worker profile override
  --model MODEL           Set model for all roles
  --director-model MODEL  Lead model override (legacy flag name)
  --worker-model MODEL    Worker model override
  --git-bin PATH          Git binary override (default: git; supports C:\... auto-convert)

Backend options:
  --teammate-mode MODE    auto|tmux|in-process|in-process-shared (default: in-process-shared)
  --tmux-layout MODE      split|window (default: split)
  --permission-mode MODE  default|acceptEdits|bypassPermissions|plan|delegate|dontAsk
  --plan-mode-required    Mark teammate config as plan-mode required
  config: AUTO_KILL_DONE_WORKER_TMUX=true|false (tmux mode에서 lead가 done 워커 pane/window 자동 종료)
  config: LEAD_WORKTREE_NAME=lead-1 (리더 전용 worktree 이름)

run/up options:
  --task TEXT             Initial task text (required for run)
  --auto-delegate         Auto-delegate initial task to role agents (default)
  --no-auto-delegate      Disable automatic worker delegation
  --dashboard             Launch team-dashboard window (tmux backend)
  --dashboard-window NAME Dashboard window name
  --dashboard-lines N     Dashboard pane lines
  --dashboard-messages N  Dashboard recent message count
  --no-attach             Do not attach tmux session after launch

teamcreate/teamdelete options:
  --team-name NAME        Team name override (default: session)
  --description TEXT      Team description
  --lead-name NAME        Team lead name (default: lead)
  --agent-type TYPE       Team lead agent type (default: team-lead)
  --replace               Overwrite existing team config on teamcreate
  --force                 Force delete even with active members/session

sendmessage options:
  --type TYPE             message|broadcast|shutdown_request|shutdown_response|shutdown_approved|shutdown_rejected|plan_approval_request|plan_approval_response|permission_request|permission_response|mode_set_request|mode_set_response
  --from NAME             Sender agent name
  --to NAME               Recipient (omit for broadcast)
  --content TEXT          Message content (or trailing positional text)
  --summary TEXT          Optional summary
  --kind KIND             Low-level bus kind override
  --meta JSON             Optional metadata JSON object
  --request-id ID         Request id for *_response
  --approve               Mark response as approved
  --reject                Mark response as rejected

Examples:
  team_codex.sh setup --repo .
  team_codex.sh run --task "Fix flaky tests" --teammate-mode in-process-shared --no-attach
  team_codex.sh run --task "UI pass" --teammate-mode tmux --tmux-layout split --dashboard
  team_codex.sh sendmessage --type shutdown_request --from lead --to worker-2 --content "stop now"
  team_codex.sh sendmessage --type shutdown_response --from lead --to worker-2 --request-id abc123 --approve --content "ok"
USAGE
}

abort() {
  echo "$*" >&2
  exit 2
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    abort "required command not found: $cmd"
  fi
}

resolve_executable_cmd() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    return 1
  fi

  if [[ "$cmd" == */* ]]; then
    if [[ -x "$cmd" && ! -d "$cmd" ]]; then
      printf '%s\n' "$cmd"
      return 0
    fi
    return 1
  fi

  local kind
  kind="$(type -t "$cmd" 2>/dev/null || true)"
  if [[ "$kind" != "file" ]]; then
    return 1
  fi

  local resolved
  resolved="$(command -v "$cmd" 2>/dev/null || true)"
  if [[ -z "$resolved" || ! -x "$resolved" || -d "$resolved" ]]; then
    return 1
  fi
  printf '%s\n' "$resolved"
}

require_subprocess_executable() {
  local cmd="$1"
  local label="$2"
  local resolved
  resolved="$(resolve_executable_cmd "$cmd" || true)"
  if [[ -z "$resolved" ]]; then
    abort "$label is not a runnable executable file: $cmd (use an installed binary path; shell alias/function is not supported)"
  fi
  printf '%s\n' "$resolved"
}

is_wsl_environment() {
  if [[ -n "${WSL_INTEROP:-}" || -n "${WSL_DISTRO_NAME:-}" ]]; then
    return 0
  fi
  if [[ -r "/proc/version" ]] && grep -qiE '(microsoft|wsl)' "/proc/version"; then
    return 0
  fi
  return 1
}

require_windows_wsl_runtime() {
  if ! is_wsl_environment; then
    abort "codex-teams is Windows+WSL only. Run this command inside WSL on a Windows host."
  fi
  if [[ ! -d "/mnt/c" ]]; then
    abort "missing Windows mount (/mnt/c). ensure WSL is configured with Windows drive mounts enabled."
  fi
  if ! command -v wslpath >/dev/null 2>&1; then
    abort "wslpath not found. install/restore WSL utilities before running codex-teams."
  fi
}

default_windows_git_bin() {
  if [[ -x "$WINDOWS_GIT_EXE_PATH" ]]; then
    printf '%s\n' "$WINDOWS_GIT_EXE_PATH"
  else
    printf '%s\n' "git"
  fi
}

is_windows_mount_path() {
  local p="${1:-}"
  [[ "$p" =~ ^/mnt/[A-Za-z]/ ]]
}

require_windows_repo_path() {
  local repo_path="${1:-}"
  if ! is_windows_mount_path "$repo_path"; then
    abort "repo must be on Windows-mounted storage (/mnt/<drive>/...). current: $repo_path"
  fi
}

default_git_bin_for_repo() {
  local repo_path="${1:-}"
  local prefer_windows_git="${CODEX_TEAM_PREFER_WINDOWS_GIT:-${CLAUDE_CODE_TEAM_PREFER_WINDOWS_GIT:-0}}"
  if [[ -n "$repo_path" ]] && ! is_windows_mount_path "$repo_path"; then
    printf '%s\n' "git"
    return 0
  fi
  if parse_bool_env "$prefer_windows_git"; then
    default_windows_git_bin
  else
    printf '%s\n' "git"
  fi
}

resolve_boot_git_bin() {
  local repo_path="${1:-}"
  local candidate=""
  if [[ -n "${CODEX_TEAM_GIT_BIN:-}" ]]; then
    candidate="${CODEX_TEAM_GIT_BIN}"
  elif [[ -n "${CLAUDE_CODE_TEAM_GIT_BIN:-}" ]]; then
    candidate="${CLAUDE_CODE_TEAM_GIT_BIN}"
  else
    candidate="$(default_git_bin_for_repo "$repo_path")"
  fi
  normalize_git_bin_path "$candidate"
}

is_non_interactive_session() {
  [[ ! -t 0 || ! -t 1 ]]
}

is_inside_tmux_sync() {
  [[ -n "${TMUX:-}" ]]
}

resolve_teammate_backend() {
  local requested="${1:-auto}"
  case "$requested" in
    tmux|in-process|in-process-shared)
      printf '%s\n' "$requested"
      return 0
      ;;
    auto)
      if is_non_interactive_session; then
        printf '%s\n' "in-process"
      elif is_inside_tmux_sync; then
        printf '%s\n' "tmux"
      else
        printf '%s\n' "in-process"
      fi
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

parse_bool_env() {
  local raw="${1:-}"
  case "${raw,,}" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_teams_enabled() {
  local feature_flag="${CODEX_EXPERIMENTAL_AGENT_TEAMS:-${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-1}}"
  local gate_flag="${CODEX_TEAMS_GATE_TENGU_AMBER_FLINT:-${CLAUDE_CODE_STATSIG_TENGU_AMBER_FLINT:-1}}"
  parse_bool_env "$feature_flag" && parse_bool_env "$gate_flag"
}

require_teams_enabled() {
  if ! is_teams_enabled; then
    abort "codex-teams disabled. set CODEX_EXPERIMENTAL_AGENT_TEAMS=1 and CODEX_TEAMS_GATE_TENGU_AMBER_FLINT=1"
  fi
}

is_abs_path() {
  local p="${1:-}"
  [[ "$p" == /* ]] || [[ "$p" =~ ^[A-Za-z]:[/\\] ]]
}

is_windows_style_path() {
  local p="${1:-}"
  [[ "$p" =~ ^[A-Za-z]:[/\\] ]] || [[ "$p" =~ ^[\\/]{2}[^\\/]+[\\/][^\\/]+ ]]
}

normalize_input_path_for_wsl() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    printf '%s\n' "$raw"
    return 0
  fi

  local candidate="$raw"
  if [[ "$candidate" == *\\* ]]; then
    candidate="${candidate//\\//}"
  fi

  if is_windows_style_path "$candidate" && command -v wslpath >/dev/null 2>&1; then
    local converted
    converted="$(wslpath -u "$candidate" 2>/dev/null || true)"
    if [[ -n "$converted" ]]; then
      printf '%s\n' "$converted"
      return 0
    fi
  fi

  printf '%s\n' "$candidate"
}

normalize_git_bin_path() {
  local raw="${1:-}"
  normalize_input_path_for_wsl "$raw"
}

is_windows_binary() {
  local bin="${1:-}"
  [[ "${bin,,}" == *.exe ]]
}

repo_path_for_git_bin() {
  local bin="$1"
  local repo_path="$2"
  if is_windows_binary "$bin" && command -v wslpath >/dev/null 2>&1; then
    local converted
    converted="$(wslpath -m "$repo_path" 2>/dev/null || true)"
    if [[ -n "$converted" ]]; then
      printf '%s\n' "$converted"
      return 0
    fi
  fi
  printf '%s\n' "$repo_path"
}

repo_path_from_git_bin() {
  local bin="$1"
  local repo_path="$2"
  if is_windows_binary "$bin" && command -v wslpath >/dev/null 2>&1; then
    local converted
    converted="$(wslpath -u "$repo_path" 2>/dev/null || true)"
    if [[ -n "$converted" ]]; then
      printf '%s\n' "$converted"
      return 0
    fi
  fi
  printf '%s\n' "$repo_path"
}

git_repo_cmd() {
  local repo_path="$1"
  shift
  local repo_for_git
  repo_for_git="$(repo_path_for_git_bin "$GIT_BIN" "$repo_path")"
  "$GIT_BIN" -C "$repo_for_git" "$@"
}

repo_has_non_git_entries() {
  local repo_path="$1"
  python3 - "$repo_path" <<'PY'
import os
import sys

root = sys.argv[1]
for name in os.listdir(root):
    if name == ".git":
        continue
    print("true")
    raise SystemExit(0)
print("false")
PY
}

ensure_git_identity_for_repo() {
  local git_bin="$1"
  local repo_path="$2"
  local repo_for_git
  repo_for_git="$(repo_path_for_git_bin "$git_bin" "$repo_path")"

  local name
  local email
  name="$("$git_bin" -C "$repo_for_git" config user.name 2>/dev/null || true)"
  email="$("$git_bin" -C "$repo_for_git" config user.email 2>/dev/null || true)"

  if [[ -z "$name" ]]; then
    name="${CODEX_TEAM_GIT_USER_NAME:-Codex Teams}"
    "$git_bin" -C "$repo_for_git" config user.name "$name"
  fi
  if [[ -z "$email" ]]; then
    email="${CODEX_TEAM_GIT_USER_EMAIL:-codex-teams@local}"
    "$git_bin" -C "$repo_for_git" config user.email "$email"
  fi
}

require_repo_ready_for_run() {
  local repo_for_git
  repo_for_git="$(repo_path_for_git_bin "$GIT_BIN" "$REPO")"
  if ! "$GIT_BIN" -C "$repo_for_git" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    abort "not a git repository: $REPO (run: codex-teams setup --repo \"$REPO\")"
  fi
  if ! "$GIT_BIN" -C "$repo_for_git" rev-parse --verify "${BASE_REF}^{commit}" >/dev/null 2>&1; then
    abort "repository has no commit for base ref '$BASE_REF'. run: codex-teams setup --repo \"$REPO\""
  fi
}

abs_path_from() {
  local base="$1"
  local p="$2"
  if is_abs_path "$p"; then
    printf '%s\n' "$p"
  else
    printf '%s/%s\n' "$base" "$p"
  fi
}

write_viewer_bridge() {
  local backend="${1:-$RESOLVED_BACKEND}"
  local layout="${2:-$TMUX_LAYOUT}"
  local bridge_path="$REPO/$VIEWER_BRIDGE_FILE"
  mkdir -p "$(dirname "$bridge_path")"
  python3 - "$bridge_path" "$TMUX_SESSION" "$ROOM" "$REPO" "$backend" "$layout" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, session, room, repo, backend, layout = sys.argv[1:7]
payload = {
    "session": session,
    "room": room,
    "repo": repo,
    "backend": backend,
    "tmux_layout": layout,
    "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "producer": "codex-teams",
}
tmp = f"{path}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

clear_viewer_bridge_if_session() {
  local bridge_path="$REPO/$VIEWER_BRIDGE_FILE"
  [[ -f "$bridge_path" ]] || return 0
  python3 - "$bridge_path" "$TMUX_SESSION" <<'PY'
import json
import os
import sys

path, session = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
except Exception:
    payload = {}
if str(payload.get("session", "")) == session:
    try:
        os.remove(path)
    except OSError:
        pass
PY
}

window_exists() {
  local session="$1"
  local window_name="$2"
  tmux list-windows -t "$session" -F "#{window_name}" 2>/dev/null | grep -Fxq "$window_name"
}

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

role_from_agent_name() {
  local agent="$1"
  case "$agent" in
    "$TEAM_LEAD_NAME") printf '%s\n' "lead" ;;
    utility-*) printf '%s\n' "utility" ;;
    worker-*) printf '%s\n' "worker" ;;
    *) printf '%s\n' "worker" ;;
  esac
}

role_default_profile() {
  local role="$1"
  case "$role" in
    lead) printf '%s\n' "$LEAD_PROFILE" ;;
    utility) printf '%s\n' "$UTILITY_PROFILE" ;;
    worker) printf '%s\n' "$WORKER_PROFILE" ;;
    *) printf '%s\n' "$WORKER_PROFILE" ;;
  esac
}

role_default_model() {
  local role="$1"
  case "$role" in
    lead) printf '%s\n' "$LEAD_MODEL" ;;
    utility) printf '%s\n' "$UTILITY_MODEL" ;;
    worker) printf '%s\n' "$WORKER_MODEL" ;;
    *) printf '%s\n' "$WORKER_MODEL" ;;
  esac
}

role_peer_name() {
  local agent="$1"
  local role
  role="$(role_from_agent_name "$agent")"
  case "$role" in
    worker) printf '%s\n' "$TEAM_LEAD_NAME" ;;
    utility) printf '%s\n' "$TEAM_LEAD_NAME" ;;
    *) printf '%s\n' "$TEAM_LEAD_NAME" ;;
  esac
}

derive_role_team_shape() {
  WORKER_COUNT="$COUNT"
  if [[ "$WORKER_COUNT" -lt 2 ]]; then
    WORKER_COUNT="2"
    if [[ -n "$AUTO_WORKERS_REASON" ]]; then
      AUTO_WORKERS_REASON="$AUTO_WORKERS_REASON,min-worker-pool"
    else
      AUTO_WORKERS_REASON="min-worker-pool"
    fi
    AUTO_WORKERS_APPLIED="true"
  fi
  UTILITY_COUNT="1"

  TEAM_AGENT_NAMES=()
  TEAM_AGENT_ROLE=()
  TEAM_AGENT_PROFILE=()
  TEAM_AGENT_MODEL=()
  BOOT_PROMPT_BY_AGENT=()

  local i agent role
  for i in $(seq 1 "$WORKER_COUNT"); do
    agent="worker-$i"
    role="worker"
    TEAM_AGENT_NAMES+=("$agent")
    TEAM_AGENT_ROLE["$agent"]="$role"
    TEAM_AGENT_PROFILE["$agent"]="$(role_default_profile "$role")"
    TEAM_AGENT_MODEL["$agent"]="$(role_default_model "$role")"
  done

  for i in $(seq 1 "$UTILITY_COUNT"); do
    agent="utility-$i"
    role="utility"
    TEAM_AGENT_NAMES+=("$agent")
    TEAM_AGENT_ROLE["$agent"]="$role"
    TEAM_AGENT_PROFILE["$agent"]="$(role_default_profile "$role")"
    TEAM_AGENT_MODEL["$agent"]="$(role_default_model "$role")"
  done

  TEAM_ROLE_SUMMARY="lead=1 worker=$WORKER_COUNT utility=$UTILITY_COUNT"
}

fs_cmd() {
  python3 "$FS" "$@"
}

load_config_or_defaults() {
  COUNT="2"
  PREFIX="worker"
  WORKTREES_DIR=".worktrees"
  LEAD_WORKTREE_NAME="lead-1"
  BASE_REF="HEAD"
  USE_BASE_WIP="false"
  ALLOW_DIRTY="true"
  TMUX_SESSION="codex-fleet"
  KILL_EXISTING_SESSION="false"
  CODEX_BIN="codex"
  DIRECTOR_PROFILE="director"
  WORKER_PROFILE="pair"
  LEAD_PROFILE="$DIRECTOR_PROFILE"
  UTILITY_PROFILE="$WORKER_PROFILE"
  DIRECTOR_INPUT_DELAY="2"
  MERGE_STRATEGY="merge"
  TEAMMATE_MODE="in-process-shared"
  TMUX_LAYOUT="split"
  PERMISSION_MODE="default"
  PLAN_MODE_REQUIRED="false"
  AUTO_DELEGATE="true"
  AUTO_KILL_DONE_WORKER_TMUX="true"
  GIT_BIN="$(default_git_bin_for_repo "$REPO")"

  if [[ ! -f "$CONFIG" ]]; then
    local default_config_path="$REPO/.codex-multi-agent.config.sh"
    if [[ "$CONFIG" == "$default_config_path" ]]; then
      ensure_default_project_config "$CONFIG"
    fi
  fi

  if [[ -f "$CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
  fi

  if [[ -z "$TEAM_NAME_OVERRIDE" ]]; then
    if [[ -n "${CODEX_TEAM_NAME:-}" ]]; then
      TEAM_NAME_OVERRIDE="$CODEX_TEAM_NAME"
    elif [[ -n "${CLAUDE_CODE_TEAM_NAME:-}" ]]; then
      TEAM_NAME_OVERRIDE="$CLAUDE_CODE_TEAM_NAME"
    fi
  fi

  if [[ -n "${CODEX_TEAMMATE_COMMAND:-}" ]]; then
    CODEX_BIN="$CODEX_TEAMMATE_COMMAND"
  elif [[ -n "${CLAUDE_CODE_TEAMMATE_COMMAND:-}" ]]; then
    CODEX_BIN="$CLAUDE_CODE_TEAMMATE_COMMAND"
  fi
  if [[ -n "${CODEX_TEAM_GIT_BIN:-}" ]]; then
    GIT_BIN="$CODEX_TEAM_GIT_BIN"
  elif [[ -n "${CLAUDE_CODE_TEAM_GIT_BIN:-}" ]]; then
    GIT_BIN="$CLAUDE_CODE_TEAM_GIT_BIN"
  fi

  if [[ -n "$DIRECTOR_PROFILE_OVERRIDE" ]]; then
    DIRECTOR_PROFILE="$DIRECTOR_PROFILE_OVERRIDE"
  fi
  if [[ -n "$WORKER_PROFILE_OVERRIDE" ]]; then
    WORKER_PROFILE="$WORKER_PROFILE_OVERRIDE"
  fi
  if [[ -n "$SESSION_OVERRIDE" ]]; then
    TMUX_SESSION="$SESSION_OVERRIDE"
  fi
  if [[ -n "$TEAMMATE_MODE_OVERRIDE" ]]; then
    TEAMMATE_MODE="$TEAMMATE_MODE_OVERRIDE"
  fi
  if [[ -n "$TMUX_LAYOUT_OVERRIDE" ]]; then
    TMUX_LAYOUT="$TMUX_LAYOUT_OVERRIDE"
  fi
  if [[ -n "$PERMISSION_MODE_OVERRIDE" ]]; then
    PERMISSION_MODE="$PERMISSION_MODE_OVERRIDE"
  fi
  if [[ -n "$PLAN_MODE_REQUIRED_OVERRIDE" ]]; then
    PLAN_MODE_REQUIRED="$PLAN_MODE_REQUIRED_OVERRIDE"
  fi
  if [[ -n "$AUTO_DELEGATE_OVERRIDE" ]]; then
    AUTO_DELEGATE="$AUTO_DELEGATE_OVERRIDE"
  fi
  if [[ -n "$GIT_BIN_OVERRIDE" ]]; then
    GIT_BIN="$GIT_BIN_OVERRIDE"
  fi
  GIT_BIN="$(normalize_git_bin_path "$GIT_BIN")"

  if [[ -z "$LEAD_PROFILE" ]]; then
    LEAD_PROFILE="$DIRECTOR_PROFILE"
  fi
  if [[ -z "$UTILITY_PROFILE" ]]; then
    UTILITY_PROFILE="$WORKER_PROFILE"
  fi

  if [[ -n "$WORKERS" ]]; then
    if [[ "$WORKERS" == "auto" ]]; then
      local orchestrator_decision
      if [[ -n "$TASK" ]]; then
        orchestrator_decision="$(orchestrator_pick_worker_count "$TASK")"
      else
        orchestrator_decision="2|manual-auto-no-task"
      fi
      COUNT="${orchestrator_decision%%|*}"
      AUTO_WORKERS_REASON="${orchestrator_decision#*|}"
      AUTO_WORKERS_APPLIED="true"
    elif [[ "$WORKERS" =~ ^[0-9]+$ ]] && [[ "$WORKERS" -ge 2 ]]; then
      COUNT="$WORKERS"
    else
      abort "--workers must be an integer >= 2 or 'auto'"
    fi
  fi

  if [[ -n "$MODEL" ]]; then
    DIRECTOR_MODEL="$MODEL"
    WORKER_MODEL="$MODEL"
    LEAD_MODEL="$MODEL"
    UTILITY_MODEL="$MODEL"
  fi

  if [[ -n "$DIRECTOR_MODEL" && -z "$LEAD_MODEL" ]]; then
    LEAD_MODEL="$DIRECTOR_MODEL"
  fi
  if [[ -n "$WORKER_MODEL" ]]; then
    if [[ -z "$UTILITY_MODEL" ]]; then UTILITY_MODEL="$WORKER_MODEL"; fi
  fi

  if [[ -z "$DIRECTOR_MODEL" ]]; then
    DIRECTOR_MODEL="$(python3 "$MODEL_RESOLVER" --project-root "$REPO" --role director --profile "$DIRECTOR_PROFILE" 2>/dev/null || true)"
  fi
  if [[ -z "$LEAD_MODEL" ]]; then
    LEAD_MODEL="$(python3 "$MODEL_RESOLVER" --project-root "$REPO" --role lead --profile "$LEAD_PROFILE" 2>/dev/null || true)"
  fi
  if [[ -z "$WORKER_MODEL" ]]; then
    WORKER_MODEL="$(python3 "$MODEL_RESOLVER" --project-root "$REPO" --role worker --profile "$WORKER_PROFILE" 2>/dev/null || true)"
  fi
  if [[ -z "$UTILITY_MODEL" ]]; then
    UTILITY_MODEL="$(python3 "$MODEL_RESOLVER" --project-root "$REPO" --role utility --profile "$UTILITY_PROFILE" 2>/dev/null || true)"
  fi

  if [[ -z "$LEAD_MODEL" ]]; then
    LEAD_MODEL="$DIRECTOR_MODEL"
  fi
  if [[ -z "$UTILITY_MODEL" ]]; then
    UTILITY_MODEL="$WORKER_MODEL"
  fi

  if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 2 ]]; then
    abort "worker count must be >= 2"
  fi
  if [[ -z "$LEAD_WORKTREE_NAME" ]]; then
    abort "LEAD_WORKTREE_NAME must not be empty"
  fi
  if ! [[ "$DIRECTOR_INPUT_DELAY" =~ ^[0-9]+$ ]]; then
    abort "DIRECTOR_INPUT_DELAY must be an integer"
  fi
  case "$USE_BASE_WIP" in true|false) ;; *) abort "USE_BASE_WIP must be true/false" ;; esac
  case "$ALLOW_DIRTY" in true|false) ;; *) abort "ALLOW_DIRTY must be true/false" ;; esac
  case "$KILL_EXISTING_SESSION" in true|false) ;; *) abort "KILL_EXISTING_SESSION must be true/false" ;; esac
  case "$TEAMMATE_MODE" in auto|tmux|in-process|in-process-shared) ;; *) abort "TEAMMATE_MODE must be auto|tmux|in-process|in-process-shared" ;; esac
  case "$TMUX_LAYOUT" in split|window) ;; *) abort "TMUX_LAYOUT must be split|window" ;; esac
  case "$PLAN_MODE_REQUIRED" in true|false) ;; *) abort "PLAN_MODE_REQUIRED must be true|false" ;; esac
  case "$AUTO_DELEGATE" in true|false) ;; *) abort "AUTO_DELEGATE must be true|false" ;; esac
  case "$AUTO_KILL_DONE_WORKER_TMUX" in true|false) ;; *) abort "AUTO_KILL_DONE_WORKER_TMUX must be true|false" ;; esac

  derive_role_team_shape

  TEAM_ROOT="$REPO/.codex-teams/$TMUX_SESSION"
  TEAM_CONFIG="$TEAM_ROOT/config.json"
  TEAM_FILE="$TEAM_ROOT/team.json"
  DB="$TEAM_ROOT/bus.sqlite"
  PROMPT_DIR="$TEAM_ROOT/prompts"
  TASKS_DIR="$TEAM_ROOT/tasks"
  LOG_DIR="$TEAM_ROOT/logs"
  WORKTREES_ROOT="$(abs_path_from "$REPO" "$WORKTREES_DIR")"
  LEAD_WORKTREE="$(abs_path_from "$WORKTREES_ROOT" "$LEAD_WORKTREE_NAME")"

  RESOLVED_BACKEND="$(resolve_teammate_backend "$TEAMMATE_MODE" || true)"
  if [[ -z "$RESOLVED_BACKEND" ]]; then
    abort "failed to resolve backend from TEAMMATE_MODE=$TEAMMATE_MODE"
  fi
  if [[ "$TEAMMATE_MODE" == "auto" ]]; then
    NORMALIZED_TEAMMATE_MODE="$TEAMMATE_MODE -> $RESOLVED_BACKEND"
  else
    NORMALIZED_TEAMMATE_MODE=""
  fi
}

init_bus_and_dirs() {
  mkdir -p "$TEAM_ROOT" "$PROMPT_DIR" "$TASKS_DIR" "$LOG_DIR"
  python3 "$BUS" --db "$DB" init >/dev/null
}

fs_member_names() {
  python3 - "$TEAM_CONFIG" <<'PY'
import json
import sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)
for m in cfg.get("members", []):
    if isinstance(m, dict) and m.get("name"):
        print(str(m.get("name")))
PY
}

fs_member_color() {
  local name="$1"
  python3 - "$TEAM_CONFIG" "$name" <<'PY'
import json
import sys
path, name = sys.argv[1], sys.argv[2]
color = "blue"
try:
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    for m in cfg.get("members", []):
        if isinstance(m, dict) and str(m.get("name", "")) == name:
            color = str(m.get("color", "blue"))
            break
except Exception:
    pass
print(color)
PY
}

register_team_members() {
  python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "system" --role "system" >/dev/null
  python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "orchestrator" --role "orchestrator" >/dev/null
  python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "monitor" --role "monitor" >/dev/null

  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local role
    role="$(role_from_agent_name "$name")"
    python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "$name" --role "$role" >/dev/null
  done < <(fs_member_names)
}

create_or_refresh_team_context() {
  local do_replace="$1"
  local team_name
  team_name="${TEAM_NAME_OVERRIDE:-$TMUX_SESSION}"

  local replace_arg=()
  if [[ "$do_replace" == "true" ]]; then
    replace_arg+=(--replace)
  fi

  fs_cmd team-create \
    --repo "$REPO" \
    --session "$TMUX_SESSION" \
    --team-name "$team_name" \
    --description "$TEAM_DESCRIPTION" \
    --agent-type "$LEAD_AGENT_TYPE" \
    --lead-name "$TEAM_LEAD_NAME" \
    --model "$LEAD_MODEL" \
    --cwd "$LEAD_WORKTREE" \
    --backend-type "$RESOLVED_BACKEND" \
    --mode "$RESOLVED_BACKEND" \
    "${replace_arg[@]}" >/dev/null

  # Keep lead/member mode aligned with the enforced runtime backend policy.
  fs_cmd member-mode --repo "$REPO" --session "$TMUX_SESSION" --ident "$TEAM_LEAD_NAME" --mode "$RESOLVED_BACKEND" >/dev/null || true

  local worker_backend="$RESOLVED_BACKEND"

  local worker
  for worker in "${TEAM_AGENT_NAMES[@]}"; do
    local wt_path="$WORKTREES_ROOT/$worker"
    local role="${TEAM_AGENT_ROLE[$worker]}"
    local model="${TEAM_AGENT_MODEL[$worker]}"
    local profile="${TEAM_AGENT_PROFILE[$worker]}"
    if [[ -z "$model" ]]; then
      model="$WORKER_MODEL"
    fi
    if [[ -z "$profile" ]]; then
      profile="$WORKER_PROFILE"
    fi
    local args=(
      member-add
      --repo "$REPO"
      --session "$TMUX_SESSION"
      --name "$worker"
      --agent-type "$role"
      --model "$model"
      --prompt ""
      --cwd "$wt_path"
      --backend-type "$worker_backend"
      --mode "$RESOLVED_BACKEND"
    )
    if [[ "$PLAN_MODE_REQUIRED" == "true" ]]; then
      args+=(--plan-mode-required)
    fi
    fs_cmd "${args[@]}" >/dev/null
  done

  fs_cmd state-context-set --repo "$REPO" --session "$TMUX_SESSION" --self-name "$TEAM_LEAD_NAME" >/dev/null
  register_team_members

  local total_members=$(( ${#TEAM_AGENT_NAMES[@]} + 1 ))
  python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind system \
    --body "team_created name=$team_name session=$TMUX_SESSION roles=[$TEAM_ROLE_SUMMARY] members=$total_members mode=$RESOLVED_BACKEND layout=$TMUX_LAYOUT" >/dev/null
}

ensure_worktrees() {
  mkdir -p "$WORKTREES_ROOT"
  # Remove stale worktree metadata so branch occupancy checks stay accurate.
  git_repo_cmd "$REPO" worktree prune --expire now >/dev/null 2>&1 || true

  local dirty="false"
  if [[ -n "$(git_repo_cmd "$REPO" status --porcelain=v1 --untracked-files=no)" ]]; then
    dirty="true"
  fi

  if [[ "$USE_BASE_WIP" == "false" && "$ALLOW_DIRTY" == "false" && "$dirty" == "true" ]]; then
    abort "repo has tracked uncommitted changes. commit/stash first or set USE_BASE_WIP=true / ALLOW_DIRTY=true in config"
  fi

  local base_commit
  if [[ "$USE_BASE_WIP" == "true" && "$dirty" == "true" ]]; then
    local wip_hash
    wip_hash="$(git_repo_cmd "$REPO" stash create "codex-teams-wip")"
    if [[ -z "$wip_hash" ]]; then
      abort "failed to create WIP snapshot for worktrees"
    fi
    local wip_ref="refs/codex/wip/team-$(date +%Y%m%d-%H%M%S)"
    git_repo_cmd "$REPO" update-ref "$wip_ref" "$wip_hash"
    base_commit="$wip_hash"
  else
    base_commit="$(git_repo_cmd "$REPO" rev-parse --verify "${BASE_REF}^{commit}")"
  fi

  local name
  local worktree_targets=("$LEAD_WORKTREE_NAME" "${TEAM_AGENT_NAMES[@]}")
  for name in "${worktree_targets[@]}"; do
    local branch="ma/$name"
    local wt_path="$WORKTREES_ROOT/$name"
    if [[ "$name" == "$LEAD_WORKTREE_NAME" ]]; then
      wt_path="$LEAD_WORKTREE"
    fi
    local wt_path_for_git
    wt_path_for_git="$(repo_path_for_git_bin "$GIT_BIN" "$wt_path")"
    local worktree_list
    worktree_list="$(git_repo_cmd "$REPO" worktree list --porcelain)"

    if grep -Fxq "worktree $wt_path" <<<"$worktree_list" || grep -Fxq "worktree $wt_path_for_git" <<<"$worktree_list"; then
      continue
    fi

    if grep -Fxq "branch refs/heads/$branch" <<<"$worktree_list"; then
      echo "skip: $branch already checked out elsewhere" >&2
      continue
    fi

    if git_repo_cmd "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
      git_repo_cmd "$REPO" worktree add "$wt_path_for_git" "$branch" >/dev/null
    else
      git_repo_cmd "$REPO" worktree add -b "$branch" "$wt_path_for_git" "$base_commit" >/dev/null
    fi
  done
}

make_wrapper() {
  WRAPPER="$TEAM_ROOT/codex-model-wrapper.sh"
  cat > "$WRAPPER" <<__WRAPPER__
#!/usr/bin/env bash
set -euo pipefail

BUS_SCRIPT="$BUS"
FS_SCRIPT="$FS"
DB_PATH="$DB"
ROOM_NAME="$ROOM"
REPO_PATH="$REPO"
SESSION_NAME="$TMUX_SESSION"
DIRECTOR_PROFILE_VALUE="$DIRECTOR_PROFILE"
WORKER_PROFILE_VALUE="$WORKER_PROFILE"
TEAM_LEAD_NAME_VALUE="$TEAM_LEAD_NAME"
DEFAULT_MODEL_VALUE="$MODEL"
CODEX_BIN_VALUE="$CODEX_BIN"
GIT_BIN_VALUE="$GIT_BIN"
PERMISSION_MODE_VALUE="$PERMISSION_MODE"

export CODEX_EXPERIMENTAL_AGENT_TEAMS=1
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
export CODEX_TEAM_GIT_BIN="\$GIT_BIN_VALUE"

agent_name="\${CODEX_TEAM_AGENT:-}"
agent_role="\${CODEX_TEAM_ROLE:-worker}"
role_profile=""
agent_cwd=""
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
if [[ -z "\$agent_name" ]]; then
  base_name="\$(basename "\$agent_cwd")"
  if [[ "\$role_profile" == "\$DIRECTOR_PROFILE_VALUE" ]]; then
    agent_name="\$TEAM_LEAD_NAME_VALUE"
    agent_role="lead"
  elif [[ "\$role_profile" == "\$WORKER_PROFILE_VALUE" ]]; then
    if [[ "\$base_name" =~ ^(worker|utility)-[0-9]+$ ]]; then
      agent_name="\$base_name"
    else
      agent_name="worker-agent"
    fi
    agent_role="worker"
  else
    agent_name="agent"
  fi
fi

notify_status() {
  local body="\$1"
  python3 "\$BUS_SCRIPT" --db "\$DB_PATH" register --room "\$ROOM_NAME" --agent "\$agent_name" --role "\$agent_role" >/dev/null 2>&1 || true
  python3 "\$BUS_SCRIPT" --db "\$DB_PATH" send --room "\$ROOM_NAME" --from "\$agent_name" --to all --kind status --body "\$body" >/dev/null 2>&1 || true
  python3 "\$FS_SCRIPT" dispatch --repo "\$REPO_PATH" --session "\$SESSION_NAME" --type status --from "\$agent_name" --recipient "\$TEAM_LEAD_NAME_VALUE" --content "\$body" --summary "runtime-status" >/dev/null 2>&1 || true
}

python3 "\$FS_SCRIPT" runtime-mark --repo "\$REPO_PATH" --session "\$SESSION_NAME" --agent "\$agent_name" --status running --pid "\$\$" >/dev/null 2>&1 || true
notify_status "online backend=tmux permission_mode=\$PERMISSION_MODE_VALUE profile=\${role_profile:-default} cwd=\$agent_cwd pid=\$\$"

cmd=("\$CODEX_BIN_VALUE")
if [[ -n "\${CODEX_TEAM_MODEL:-}" ]]; then
  cmd+=(-m "\$CODEX_TEAM_MODEL")
elif [[ -n "\$DEFAULT_MODEL_VALUE" ]]; then
  cmd+=(-m "\$DEFAULT_MODEL_VALUE")
fi

set +e
"\${cmd[@]}" "\${args[@]}"
exit_code=\$?
set -e

python3 "\$FS_SCRIPT" runtime-mark --repo "\$REPO_PATH" --session "\$SESSION_NAME" --agent "\$agent_name" --status terminated --pid "\$\$" >/dev/null 2>&1 || true
notify_status "offline backend=tmux exit=\$exit_code cwd=\$agent_cwd"
exit "\$exit_code"
__WRAPPER__
  chmod +x "$WRAPPER"
}

make_pane_command() {
  local agent="$1"
  local role="$2"
  local profile="$3"
  local cwd="$4"
  local model="${5:-}"
  local initial_prompt="${6:-}"
  local cmd
  printf -v cmd 'CODEX_TEAM_AGENT=%q CODEX_TEAM_ROLE=%q CODEX_TEAM_MODEL=%q %q -p %q -C %q' "$agent" "$role" "$model" "$WRAPPER" "$profile" "$cwd"
  if [[ -n "$initial_prompt" ]]; then
    local quoted_prompt
    printf -v quoted_prompt '%q' "$initial_prompt"
    cmd+=" $quoted_prompt"
  fi
  printf '%s\n' "$cmd"
}

boot_prompt_available() {
  local agent="$1"
  [[ -n "${BOOT_PROMPT_BY_AGENT[$agent]+x}" && -n "${BOOT_PROMPT_BY_AGENT[$agent]}" ]]
}

agent_boot_prompt() {
  local agent="$1"
  if boot_prompt_available "$agent"; then
    printf '%s\n' "${BOOT_PROMPT_BY_AGENT[$agent]}"
  fi
}

record_tmux_runtime() {
  local agent="$1"
  local pane_id="$2"
  local window_name="$3"
  fs_cmd runtime-set --repo "$REPO" --session "$TMUX_SESSION" --agent "$agent" --backend tmux --status running --pane-id "$pane_id" --window "$window_name" >/dev/null
}

set_tmux_pane_color() {
  local pane_target="$1"
  local agent="$2"
  local color
  color="$(fs_member_color "$agent")"
  local border
  border="$(fs_cmd color-map --color "$color" 2>/dev/null || echo default)"
  tmux select-pane -t "$pane_target" -P "pane-border-style=fg=$border" >/dev/null 2>&1 || true
  tmux select-pane -t "$pane_target" -P "pane-active-border-style=fg=$border" >/dev/null 2>&1 || true
}

launch_tmux_split_backend() {
  if [[ ! -d "$LEAD_WORKTREE" ]]; then
    abort "missing lead worktree: $LEAD_WORKTREE"
  fi
  if tmux has-session -t "$TMUX_SESSION" >/dev/null 2>&1; then
    if [[ "$KILL_EXISTING_SESSION" == "true" ]]; then
      tmux kill-session -t "$TMUX_SESSION"
    else
      echo "tmux session already exists: $TMUX_SESSION"
      if [[ "$NO_ATTACH" != "true" ]]; then
        tmux attach -t "$TMUX_SESSION"
      fi
      return 0
    fi
  fi

  tmux new-session -d -s "$TMUX_SESSION" -n "$SWARM_WINDOW" -c "$LEAD_WORKTREE"
  tmux set-option -t "$TMUX_SESSION" -g remain-on-exit on >/dev/null 2>&1 || true
  tmux set-option -t "$TMUX_SESSION" -g pane-border-status top >/dev/null 2>&1 || true
  tmux set-option -t "$TMUX_SESSION" -g pane-border-format '#{pane_title}' >/dev/null 2>&1 || true

  tmux select-pane -t "$TMUX_SESSION:$SWARM_WINDOW.0" -T "$TEAM_LEAD_NAME"
  local director_cmd
  local lead_boot_prompt
  lead_boot_prompt="$(agent_boot_prompt "$TEAM_LEAD_NAME")"
  director_cmd="$(make_pane_command "$TEAM_LEAD_NAME" "lead" "$LEAD_PROFILE" "$LEAD_WORKTREE" "$LEAD_MODEL" "$lead_boot_prompt")"
  tmux send-keys -t "$TMUX_SESSION:$SWARM_WINDOW.0" "$director_cmd" C-m
  local lead_pane
  lead_pane="$(tmux display-message -p -t "$TMUX_SESSION:$SWARM_WINDOW.0" '#{pane_id}')"
  record_tmux_runtime "$TEAM_LEAD_NAME" "$lead_pane" "$SWARM_WINDOW"
  set_tmux_pane_color "$TMUX_SESSION:$SWARM_WINDOW.0" "$TEAM_LEAD_NAME"

  local agent
  for agent in "${TEAM_AGENT_NAMES[@]}"; do
    local wt_path="$WORKTREES_ROOT/$agent"
    local role="${TEAM_AGENT_ROLE[$agent]}"
    local profile="${TEAM_AGENT_PROFILE[$agent]}"
    local model="${TEAM_AGENT_MODEL[$agent]}"
    if [[ ! -d "$wt_path" ]]; then
      echo "skip missing worktree: $wt_path" >&2
      continue
    fi

    local pane_id
    pane_id="$(tmux split-window -P -F '#{pane_id}' -t "$TMUX_SESSION:$SWARM_WINDOW" -c "$wt_path")"
    tmux select-pane -t "$pane_id" -T "$agent"

    local worker_cmd
    local worker_boot_prompt
    worker_boot_prompt="$(agent_boot_prompt "$agent")"
    worker_cmd="$(make_pane_command "$agent" "$role" "$profile" "$wt_path" "$model" "$worker_boot_prompt")"
    tmux send-keys -t "$pane_id" "$worker_cmd" C-m

    record_tmux_runtime "$agent" "$pane_id" "$SWARM_WINDOW"
    set_tmux_pane_color "$pane_id" "$agent"

    tmux select-layout -t "$TMUX_SESSION:$SWARM_WINDOW" tiled >/dev/null 2>&1 || true
  done

  tmux select-layout -t "$TMUX_SESSION:$SWARM_WINDOW" tiled >/dev/null 2>&1 || true
  tmux select-pane -t "$TMUX_SESSION:$SWARM_WINDOW.0"
}

launch_tmux_window_backend() {
  if [[ ! -d "$LEAD_WORKTREE" ]]; then
    abort "missing lead worktree: $LEAD_WORKTREE"
  fi
  if tmux has-session -t "$TMUX_SESSION" >/dev/null 2>&1; then
    if [[ "$KILL_EXISTING_SESSION" == "true" ]]; then
      tmux kill-session -t "$TMUX_SESSION"
    else
      echo "tmux session already exists: $TMUX_SESSION"
      if [[ "$NO_ATTACH" != "true" ]]; then
        tmux attach -t "$TMUX_SESSION"
      fi
      return 0
    fi
  fi

  tmux new-session -d -s "$TMUX_SESSION" -n "$TEAM_LEAD_NAME" -c "$LEAD_WORKTREE"
  tmux set-option -t "$TMUX_SESSION" -g remain-on-exit on >/dev/null 2>&1 || true
  local lead_cmd
  local lead_boot_prompt
  lead_boot_prompt="$(agent_boot_prompt "$TEAM_LEAD_NAME")"
  lead_cmd="$(make_pane_command "$TEAM_LEAD_NAME" "lead" "$LEAD_PROFILE" "$LEAD_WORKTREE" "$LEAD_MODEL" "$lead_boot_prompt")"
  tmux send-keys -t "$TMUX_SESSION:$TEAM_LEAD_NAME.0" "$lead_cmd" C-m
  local lead_pane
  lead_pane="$(tmux display-message -p -t "$TMUX_SESSION:$TEAM_LEAD_NAME.0" '#{pane_id}')"
  record_tmux_runtime "$TEAM_LEAD_NAME" "$lead_pane" "$TEAM_LEAD_NAME"
  tmux select-pane -t "$TMUX_SESSION:$TEAM_LEAD_NAME.0" -T "$TEAM_LEAD_NAME"
  set_tmux_pane_color "$TMUX_SESSION:$TEAM_LEAD_NAME.0" "$TEAM_LEAD_NAME"

  local agent
  for agent in "${TEAM_AGENT_NAMES[@]}"; do
    local wt_path="$WORKTREES_ROOT/$agent"
    local role="${TEAM_AGENT_ROLE[$agent]}"
    local profile="${TEAM_AGENT_PROFILE[$agent]}"
    local model="${TEAM_AGENT_MODEL[$agent]}"
    if [[ ! -d "$wt_path" ]]; then
      echo "skip missing worktree: $wt_path" >&2
      continue
    fi
    tmux new-window -t "$TMUX_SESSION" -n "$agent" -c "$wt_path"
    local worker_cmd
    local worker_boot_prompt
    worker_boot_prompt="$(agent_boot_prompt "$agent")"
    worker_cmd="$(make_pane_command "$agent" "$role" "$profile" "$wt_path" "$model" "$worker_boot_prompt")"
    tmux send-keys -t "$TMUX_SESSION:$agent.0" "$worker_cmd" C-m
    local pane_id
    pane_id="$(tmux display-message -p -t "$TMUX_SESSION:$agent.0" '#{pane_id}')"
    record_tmux_runtime "$agent" "$pane_id" "$agent"
    tmux select-pane -t "$TMUX_SESSION:$agent.0" -T "$agent"
    set_tmux_pane_color "$TMUX_SESSION:$agent.0" "$agent"
  done

  tmux select-window -t "$TMUX_SESSION:$TEAM_LEAD_NAME"
}

spawn_inprocess_backend() {
  require_cmd nohup
  mkdir -p "$LOG_DIR"

  local inprocess_agents=("$TEAM_LEAD_NAME" "${TEAM_AGENT_NAMES[@]}")
  local agent
  for agent in "${inprocess_agents[@]}"; do
    local wt_path
    local role
    local profile
    local model
    if [[ "$agent" == "$TEAM_LEAD_NAME" ]]; then
      wt_path="$LEAD_WORKTREE"
      role="lead"
      profile="$LEAD_PROFILE"
      model="$LEAD_MODEL"
    else
      wt_path="$WORKTREES_ROOT/$agent"
      role="${TEAM_AGENT_ROLE[$agent]}"
      profile="${TEAM_AGENT_PROFILE[$agent]}"
      model="${TEAM_AGENT_MODEL[$agent]}"
    fi
    if [[ ! -d "$wt_path" ]]; then
      echo "skip missing worktree: $wt_path" >&2
      continue
    fi

    local log_file="$LOG_DIR/$agent.log"
    local args=(
      python3 "$INPROCESS_AGENT"
      --repo "$REPO"
      --session "$TMUX_SESSION"
      --room "$ROOM"
      --agent "$agent"
      --role "$role"
      --cwd "$wt_path"
      --profile "$profile"
      --model "$model"
      --codex-bin "$CODEX_BIN"
      --permission-mode "$PERMISSION_MODE"
    )
    if [[ "$PLAN_MODE_REQUIRED" == "true" ]]; then
      args+=(--plan-mode-required)
    fi

    nohup "${args[@]}" >"$log_file" 2>&1 &
    local pid=$!

    fs_cmd runtime-set --repo "$REPO" --session "$TMUX_SESSION" --agent "$agent" --backend in-process --status running --pid "$pid" --window in-process >/dev/null
    python3 "$BUS" --db "$DB" register --room "$ROOM" --agent "$agent" --role "$role" >/dev/null
    python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind status --body "spawned in-process agent=$agent pid=$pid log=$log_file" >/dev/null
  done
}

spawn_inprocess_shared_backend() {
  require_cmd nohup
  mkdir -p "$LOG_DIR"

  local hub_log="$LOG_DIR/inprocess-hub.log"
  local hub_agents=("$TEAM_LEAD_NAME" "${TEAM_AGENT_NAMES[@]}")
  local hub_count="${#hub_agents[@]}"
  local agents_csv
  agents_csv="$(IFS=,; echo "${hub_agents[*]}")"
  local args=(
    python3 "$INPROCESS_HUB"
    --repo "$REPO"
    --session "$TMUX_SESSION"
    --room "$ROOM"
    --prefix "$PREFIX"
    --count "$COUNT"
    --agents-csv "$agents_csv"
    --worktrees-root "$WORKTREES_ROOT"
    --profile "$WORKER_PROFILE"
    --model "$WORKER_MODEL"
    --lead-name "$TEAM_LEAD_NAME"
    --lead-cwd "$LEAD_WORKTREE"
    --lead-profile "$LEAD_PROFILE"
    --lead-model "$LEAD_MODEL"
    --codex-bin "$CODEX_BIN"
    --permission-mode "$PERMISSION_MODE"
  )
  if [[ "$PLAN_MODE_REQUIRED" == "true" ]]; then
    args+=(--plan-mode-required)
  fi

  nohup "${args[@]}" >"$hub_log" 2>&1 &
  local pid=$!

  python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind status \
    --body "spawned in-process shared hub pid=$pid members=$hub_count roles=[$TEAM_ROLE_SUMMARY] log=$hub_log" >/dev/null
}

launch_aux_windows() {
  if [[ "$RESOLVED_BACKEND" != "tmux" ]]; then
    return 0
  fi

  if window_exists "$TMUX_SESSION" "$MONITOR_WINDOW"; then
    tmux send-keys -t "$TMUX_SESSION:$MONITOR_WINDOW" C-c >/dev/null 2>&1 || true
  else
    tmux new-window -t "$TMUX_SESSION" -n "$MONITOR_WINDOW" -c "$REPO"
  fi
  tmux select-pane -t "$TMUX_SESSION:$MONITOR_WINDOW.0" -T "monitor" >/dev/null 2>&1 || true
  tmux send-keys -t "$TMUX_SESSION:$MONITOR_WINDOW" "TEAM_DB='$DB' '$TAIL_SCRIPT' --room '$ROOM' --all monitor" C-m

  if [[ "$DASHBOARD" == "true" ]]; then
    if window_exists "$TMUX_SESSION" "$DASHBOARD_WINDOW"; then
      tmux send-keys -t "$TMUX_SESSION:$DASHBOARD_WINDOW" C-c >/dev/null 2>&1 || true
    else
      tmux new-window -t "$TMUX_SESSION" -n "$DASHBOARD_WINDOW" -c "$REPO"
    fi
    tmux select-pane -t "$TMUX_SESSION:$DASHBOARD_WINDOW.0" -T "dashboard" >/dev/null 2>&1 || true
    tmux send-keys -t "$TMUX_SESSION:$DASHBOARD_WINDOW" \
      "TEAM_DB='$DB' '$DASHBOARD_SCRIPT' --session '$TMUX_SESSION' --repo '$REPO' --room '$ROOM' --lines '$DASHBOARD_LINES' --messages '$DASHBOARD_MESSAGES'" C-m
  fi

  if window_exists "$TMUX_SESSION" "$PULSE_WINDOW"; then
    tmux send-keys -t "$TMUX_SESSION:$PULSE_WINDOW" C-c >/dev/null 2>&1 || true
  else
    tmux new-window -t "$TMUX_SESSION" -n "$PULSE_WINDOW" -c "$REPO"
  fi
  tmux select-pane -t "$TMUX_SESSION:$PULSE_WINDOW.0" -T "pulse" >/dev/null 2>&1 || true
  local pulse_agents
  pulse_agents="$(IFS=,; echo "${TEAM_AGENT_NAMES[*]}")"
  tmux send-keys -t "$TMUX_SESSION:$PULSE_WINDOW" \
    "TEAM_DB='$DB' '$PULSE_SCRIPT' --session '$TMUX_SESSION' --window '$SWARM_WINDOW' --room '$ROOM' --agents-csv '$pulse_agents' --lead-name '$TEAM_LEAD_NAME'" C-m

  if window_exists "$TMUX_SESSION" "$MAILBOX_WINDOW"; then
    tmux send-keys -t "$TMUX_SESSION:$MAILBOX_WINDOW" C-c >/dev/null 2>&1 || true
  else
    tmux new-window -t "$TMUX_SESSION" -n "$MAILBOX_WINDOW" -c "$REPO"
  fi
  tmux select-pane -t "$TMUX_SESSION:$MAILBOX_WINDOW.0" -T "mailbox-bridge" >/dev/null 2>&1 || true
  tmux send-keys -t "$TMUX_SESSION:$MAILBOX_WINDOW" \
    "python3 '$TMUX_MAILBOX_BRIDGE' --repo '$REPO' --session '$TMUX_SESSION' --room '$ROOM' --tmux-session '$TMUX_SESSION' --lead-name '$TEAM_LEAD_NAME' --auto-kill-done-workers '$AUTO_KILL_DONE_WORKER_TMUX'" C-m
}

role_primary_objective() {
  local role="$1"
  case "$role" in
    worker)
      printf '%s\n' "Implement scoped code changes with minimal blast radius and provide concrete validation output."
      ;;
    utility)
      printf '%s\n' "Own git/release operations: integrate approved changes, push branch, and execute merge flow with traceable logs."
      ;;
    *)
      printf '%s\n' "Execute assigned scope and provide auditable evidence."
      ;;
  esac
}

build_role_task_prompt() {
  local agent="$1"
  local role="$2"
  local idx="$3"
  local total="$4"
  local user_task="$5"
  local peer
  peer="$(role_peer_name "$agent")"
  local focus
  focus="$(role_primary_objective "$role")"
  local role_specific_contract=""
  if [[ "$role" == "worker" ]]; then
    role_specific_contract="$(cat <<EOF
7. Maintain continuous peer collaboration: when your output depends on another worker/utility, send \`question\` and keep Q/A looping until dependency is closed.
8. If anything is unknown mid-task, ask lead immediately with \`question\` (summary: research-request); do not guess critical requirements.
9. If lead responds with refined guidance/research, convert it into concrete next edits/tests and report back with \`status\`.
EOF
)"
  elif [[ "$role" == "utility" ]]; then
    role_specific_contract="$(cat <<EOF
7. Keep continuous sync with workers on release-impacting changes; resolve interface gaps through \`question\`/\`answer\` loops.
8. If release/merge context is unclear, ask lead and wait for explicit handoff approval.
9. Use the configured git binary for push/merge operations when available: \`"$GIT_BIN"\`.
EOF
)"
  fi
  cat <<EOF
[Codex Teams]
team=$TMUX_SESSION lead=$TEAM_LEAD_NAME agent=$agent role=$role index=$idx/$total
peer_collaboration_target=$peer

Primary objective:
$focus

User request:
$user_task

Execution contract:
1. Start immediately and keep changes scoped to your role responsibility.
2. Lead($TEAM_LEAD_NAME) owns research/planning/review orchestration and must not execute implementation tasks. Escalate blockers/questions to lead.
3. Realtime collaboration is mandatory and continuous: when interfaces/requirements are unclear, ask $peer with \`question\`, reply with \`answer\`, and keep iterative loops until closed.
4. Send progress and completion updates:
   codex-teams sendmessage --session "$TMUX_SESSION" --room "$ROOM" --type status --from "$agent" --to "$TEAM_LEAD_NAME" --summary "<progress|done|blocker>" --content "<update>"
5. Include evidence in done: changed files + validation command outputs + residual risk.
6. Utility handoff: once lead approves completion, utility handles git push and merge flow.
$role_specific_contract
EOF
}

build_lead_task_prompt() {
  local task_text="$1"
  cat <<EOF
[Lead Mission]
You are the lead orchestrator for team=$TMUX_SESSION.

User request:
$task_text

Operating policy:
1. Perform requirement analysis and research synthesis.
2. Produce a concrete execution plan.
3. Adjust worker allocation within configured worker pool.
4. Delegate implementation tasks to worker-* agents.
5. Coordinate in real time, intervene on blockers, and keep worker/utility collaboration loops active until resolution.
6. Handoff approved changes to utility-1 for git push and merge workflow.
7. If any worker asks \`question\` with unknowns, run focused research (repo + web/docs as needed) and send refined guidance back as follow-up \`task\` or \`answer\`.
8. For each unanswered worker question/blocker, assign owner + deadline and keep follow-up until closed.

Hard constraint:
- Do not implement code directly; lead is orchestration-only.
EOF
}

prepare_initial_boot_prompts() {
  BOOT_PROMPT_BY_AGENT=()
  if [[ -z "$TASK" ]]; then
    return 0
  fi

  BOOT_PROMPT_BY_AGENT["$TEAM_LEAD_NAME"]="$(build_lead_task_prompt "$TASK")"
  if [[ "$AUTO_DELEGATE" != "true" ]]; then
    return 0
  fi

  local i=0
  local total="${#TEAM_AGENT_NAMES[@]}"
  local agent
  for agent in "${TEAM_AGENT_NAMES[@]}"; do
    i=$((i + 1))
    local role="${TEAM_AGENT_ROLE[$agent]}"
    BOOT_PROMPT_BY_AGENT["$agent"]="$(build_role_task_prompt "$agent" "$role" "$i" "$total" "$TASK")"
  done
}

announce_collaboration_workflow() {
  local workflow_summary
  workflow_summary="workflow-fixed lead-research+plan->delegate->peer-qa(continuous)->on-demand-research-by-lead->lead-review->utility-push/merge; lead=orchestration-only; unknowns=worker-question->lead-research->worker-answer/task; role-shape=[$TEAM_ROLE_SUMMARY]; policy=default-worker-pool-2(expand-with---workers)"
  python3 "$BUS" --db "$DB" send --room "$ROOM" --from orchestrator --to all --kind status --body "$workflow_summary" >/dev/null
  fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type status --from orchestrator --recipient all --summary "workflow-fixed" --content "$workflow_summary" >/dev/null || true
}

tmux_send_worker_task() {
  local agent="$1"
  local prompt="$2"
  local pane
  pane="$(runtime_read_field "$agent" paneId)"
  if [[ -z "$pane" ]]; then
    return 0
  fi
  tmux send-keys -t "$pane" -l -- "$prompt"
  tmux send-keys -t "$pane" C-m
}

delegate_initial_task_to_role_agents() {
  local task_text="$1"
  local i=0
  local total="${#TEAM_AGENT_NAMES[@]}"
  local agent
  for agent in "${TEAM_AGENT_NAMES[@]}"; do
    i=$((i + 1))
    local role="${TEAM_AGENT_ROLE[$agent]}"
    local delegated
    delegated="$(build_role_task_prompt "$agent" "$role" "$i" "$total" "$task_text")"
    fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type task --from "$TEAM_LEAD_NAME" --recipient "$agent" --content "$delegated" --summary "delegated-initial-task-$agent" >/dev/null
    python3 "$BUS" --db "$DB" send --room "$ROOM" --from "$TEAM_LEAD_NAME" --to "$agent" --kind task --body "$delegated" >/dev/null
    if [[ "$RESOLVED_BACKEND" == "tmux" ]]; then
      if ! boot_prompt_available "$agent"; then
        tmux_send_worker_task "$agent" "$delegated" || true
      fi
    fi
  done
}

inject_initial_task() {
  if [[ -z "$TASK" ]]; then
    return 0
  fi

  local orchestration_note
  orchestration_note="lead-orchestration-only task_received=true auto_delegate=$AUTO_DELEGATE roles=[$TEAM_ROLE_SUMMARY]"
  python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to "$TEAM_LEAD_NAME" --kind status --body "$orchestration_note" >/dev/null
  fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type status --from system --recipient "$TEAM_LEAD_NAME" --content "$orchestration_note" --summary "initial-orchestration" >/dev/null

  local lead_task_prompt
  lead_task_prompt="$(build_lead_task_prompt "$TASK")"
  python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to "$TEAM_LEAD_NAME" --kind task --body "$lead_task_prompt" >/dev/null
  fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type task --from system --recipient "$TEAM_LEAD_NAME" --content "$lead_task_prompt" --summary "lead-mission" >/dev/null
  if [[ "$RESOLVED_BACKEND" == "tmux" ]]; then
    if ! boot_prompt_available "$TEAM_LEAD_NAME"; then
      sleep "$DIRECTOR_INPUT_DELAY"
      tmux_send_worker_task "$TEAM_LEAD_NAME" "$lead_task_prompt" || true
    fi
  fi

  if [[ "$AUTO_DELEGATE" == "true" ]]; then
    delegate_initial_task_to_role_agents "$TASK"
  fi
}

print_start_summary() {
  echo "Codex Teams ready"
  echo "- repo: $REPO"
  echo "- session: $TMUX_SESSION"
  echo "- backend: $RESOLVED_BACKEND"
  if [[ -n "$NORMALIZED_TEAMMATE_MODE" ]]; then
    echo "- backend request normalized: $NORMALIZED_TEAMMATE_MODE"
  fi
  if [[ "$RESOLVED_BACKEND" == "tmux" ]]; then
    echo "- tmux layout: $TMUX_LAYOUT"
    echo "- tmux mailbox bridge window: $MAILBOX_WINDOW"
    echo "- tmux auto-kill done worker: $AUTO_KILL_DONE_WORKER_TMUX"
  fi
  local total_members=$(( ${#TEAM_AGENT_NAMES[@]} + 1 ))
  echo "- role members: $total_members ($TEAM_ROLE_SUMMARY)"
  echo "- lead worktree: $LEAD_WORKTREE"
  echo "- worker pool: $WORKER_COUNT"
  if [[ "$AUTO_WORKERS_APPLIED" == "true" ]]; then
    echo "- worker scaling: auto ($AUTO_WORKERS_REASON)"
  fi
  echo "- auto delegate: $AUTO_DELEGATE"
  echo "- room: $ROOM"
  echo "- bus db: $DB"
  echo "- git bin: $GIT_BIN"
  echo "- team config: $TEAM_CONFIG"
  echo "- state: $TEAM_ROOT/state.json"
  echo "- viewer bridge: $REPO/$VIEWER_BRIDGE_FILE"
  if [[ -n "$LEAD_MODEL" || -n "$WORKER_MODEL" || -n "$UTILITY_MODEL" ]]; then
    echo "- models: lead=${LEAD_MODEL:-<default>} worker=${WORKER_MODEL:-<default>} utility=${UTILITY_MODEL:-<default>}"
  fi
  if [[ "$RESOLVED_BACKEND" == "in-process" ]]; then
    echo "- logs: $LOG_DIR/<agent>.log"
  elif [[ "$RESOLVED_BACKEND" == "in-process-shared" ]]; then
    echo "- logs: $LOG_DIR/inprocess-hub.log"
  fi
  echo "- status: TEAM_DB='$DB' '$STATUS' --room '$ROOM'"
  echo "- mailbox: TEAM_DB='$DB' '$MAILBOX' --repo '$REPO' --session '$TMUX_SESSION' inbox <agent> --unread"
  echo "- control: TEAM_DB='$DB' '$CONTROL' --repo '$REPO' --session '$TMUX_SESSION' request --type plan_approval <from> <to> <body>"
}

run_swarm() {
  require_cmd "$GIT_BIN"
  require_cmd python3
  CODEX_BIN="$(require_subprocess_executable "$CODEX_BIN" "codex binary")"
  require_repo_ready_for_run

  if [[ "$COMMAND" == "run" && -z "$TASK" ]]; then
    abort "--task is required for run"
  fi

  init_bus_and_dirs
  ensure_worktrees
  create_or_refresh_team_context true

  prepare_initial_boot_prompts
  if [[ "$RESOLVED_BACKEND" == "tmux" ]]; then
    require_cmd tmux
    make_wrapper
    if [[ "$TMUX_LAYOUT" == "split" ]]; then
      launch_tmux_split_backend
    else
      launch_tmux_window_backend
    fi
    launch_aux_windows
  else
    if [[ "$RESOLVED_BACKEND" == "in-process-shared" ]]; then
      spawn_inprocess_shared_backend
    else
      spawn_inprocess_backend
    fi
  fi

  write_viewer_bridge "$RESOLVED_BACKEND" "$TMUX_LAYOUT"

  local total_members=$(( ${#TEAM_AGENT_NAMES[@]} + 1 ))
  python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind system \
    --body "session=$TMUX_SESSION started via codex-teams backend=$RESOLVED_BACKEND members=$total_members role_shape=[$TEAM_ROLE_SUMMARY] layout=$TMUX_LAYOUT permission_mode=$PERMISSION_MODE" >/dev/null
  if [[ "$AUTO_WORKERS_APPLIED" == "true" ]]; then
    python3 "$BUS" --db "$DB" send --room "$ROOM" --from orchestrator --to all --kind status \
      --body "auto-worker-scaling selected worker_pool=$WORKER_COUNT role_shape=[$TEAM_ROLE_SUMMARY] reason=$AUTO_WORKERS_REASON" >/dev/null
  fi
  announce_collaboration_workflow

  inject_initial_task
  print_start_summary

  if [[ "$RESOLVED_BACKEND" == "tmux" && "$NO_ATTACH" != "true" ]]; then
    tmux attach -t "$TMUX_SESSION"
  fi
}

run_status() {
  local runtime_backend
  runtime_backend="$(python3 - "$TEAM_ROOT/runtime.json" "$TEAM_LEAD_NAME" <<'PY'
import json
import sys

path = sys.argv[1]
lead = sys.argv[2]
backend = ""

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    agents = data.get("agents", {})
    if isinstance(agents, dict):
        lead_entry = agents.get(lead)
        if isinstance(lead_entry, dict):
            candidate = str(lead_entry.get("backend", "")).strip()
            if candidate:
                backend = candidate
        if not backend:
            for entry in agents.values():
                if isinstance(entry, dict):
                    candidate = str(entry.get("backend", "")).strip()
                    if candidate:
                        backend = candidate
                        break
except Exception:
    backend = ""

if backend:
    print(backend)
PY
)"

  echo "repo=$REPO"
  echo "session=$TMUX_SESSION"
  echo "room=$ROOM"
  echo "db=$DB"
  if [[ -n "$runtime_backend" ]]; then
    echo "backend=$runtime_backend"
    if [[ "$runtime_backend" != "$RESOLVED_BACKEND" ]]; then
      echo "backend-resolved=$RESOLVED_BACKEND"
    fi
  else
    echo "backend=$RESOLVED_BACKEND"
  fi

  echo ""
  echo "[filesystem runtime]"
  fs_cmd runtime-list --repo "$REPO" --session "$TMUX_SESSION" --prune-write || true

  echo ""
  echo "[filesystem state]"
  fs_cmd state-get --repo "$REPO" --session "$TMUX_SESSION" --compact || true

  if tmux has-session -t "$TMUX_SESSION" >/dev/null 2>&1; then
    echo ""
    echo "[tmux panes]"
    tmux list-panes -s -t "$TMUX_SESSION" -F "session=#{session_name} window=#{window_name} pane=#{pane_index} title=#{pane_title} cmd=#{pane_current_command} path=#{pane_current_path}"
  else
    echo ""
    echo "tmux session not running: $TMUX_SESSION"
  fi

  if [[ -f "$DB" ]]; then
    echo ""
    TEAM_DB="$DB" "$STATUS" --room "$ROOM"
  else
    echo ""
    echo "bus db missing: $DB"
  fi
}

runtime_read_field() {
  local agent="$1"
  local field="$2"
  python3 - "$TEAM_ROOT/runtime.json" "$agent" "$field" <<'PY'
import json
import sys
path, agent, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "r", encoding="utf-8") as f:
        rt = json.load(f)
except Exception:
    print("")
    raise SystemExit(0)
rec = rt.get("agents", {}).get(agent, {})
if not isinstance(rec, dict):
    print("")
    raise SystemExit(0)
print(rec.get(field, ""))
PY
}

apply_shutdown_target() {
  local target="$1"
  local backend
  backend="$(runtime_read_field "$target" backend)"
  local pid
  pid="$(runtime_read_field "$target" pid)"
  local pane
  pane="$(runtime_read_field "$target" paneId)"
  local window
  window="$(runtime_read_field "$target" window)"

  if [[ "$backend" == "tmux" && -n "$pane" ]]; then
    if tmux has-session -t "$TMUX_SESSION" >/dev/null 2>&1; then
      tmux kill-pane -t "$pane" >/dev/null 2>&1 || true
    fi
    fs_cmd runtime-mark --repo "$REPO" --session "$TMUX_SESSION" --agent "$target" --status terminated >/dev/null || true
  elif [[ "$backend" == "tmux" && -n "$window" ]]; then
    if tmux has-session -t "$TMUX_SESSION" >/dev/null 2>&1; then
      tmux kill-window -t "$TMUX_SESSION:$window" >/dev/null 2>&1 || true
    fi
    fs_cmd runtime-mark --repo "$REPO" --session "$TMUX_SESSION" --agent "$target" --status terminated >/dev/null || true
  elif [[ "$backend" == "in-process" || "$backend" == "in-process-shared" ]]; then
    fs_cmd runtime-kill --repo "$REPO" --session "$TMUX_SESSION" --agent "$target" --signal term >/dev/null || true
  elif [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
    kill "$pid" >/dev/null 2>&1 || true
    fs_cmd runtime-mark --repo "$REPO" --session "$TMUX_SESSION" --agent "$target" --status terminated >/dev/null || true
  fi

  python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind status --body "shutdown-applied target=$target backend=${backend:-unknown}" >/dev/null || true
}

force_terminate_runtime_agents() {
  if [[ ! -f "$TEAM_ROOT/runtime.json" ]]; then
    return 0
  fi

  local running_agents
  running_agents="$(python3 - "$TEAM_ROOT/runtime.json" <<'PY'
import json
import sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        runtime = json.load(f)
except Exception:
    raise SystemExit(0)
agents = runtime.get("agents", {})
if not isinstance(agents, dict):
    raise SystemExit(0)
for name, record in agents.items():
    if isinstance(record, dict) and str(record.get("status", "")) == "running":
        print(str(name))
PY
)"
  local agent
  while IFS= read -r agent; do
    [[ -z "$agent" ]] && continue
    fs_cmd runtime-kill --repo "$REPO" --session "$TMUX_SESSION" --agent "$agent" --signal term >/dev/null 2>&1 || true
  done <<< "$running_agents"
}

cmd_teamcreate() {
  load_config_or_defaults
  init_bus_and_dirs
  create_or_refresh_team_context "$TEAMCREATE_REPLACE"
  write_viewer_bridge "$RESOLVED_BACKEND" "$TMUX_LAYOUT"
  echo "team context ready"
  echo "- config: $TEAM_CONFIG"
  echo "- bus: $DB"
  echo "- state: $TEAM_ROOT/state.json"
  echo "- viewer bridge: $REPO/$VIEWER_BRIDGE_FILE"
}

ensure_default_project_config() {
  local config_path="${1:-$REPO/.codex-multi-agent.config.sh}"
  if [[ -f "$config_path" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$config_path")"
  cat > "$config_path" <<'EOF'
#!/usr/bin/env bash
# Project config for codex multi-agent orchestration.
# Topology is fixed by codex-teams runtime: lead x1 + worker xN + utility x1.

# Number of workers (pair sessions).
COUNT=2

# Worker naming prefix: worker-1 ... worker-N
PREFIX="worker"

# Where worker worktrees are created (relative to repo root or absolute path).
WORKTREES_DIR=".worktrees"
LEAD_WORKTREE_NAME="lead-1"

# Base commit/ref for new worker branches.
BASE_REF="HEAD"

# true: capture tracked uncommitted changes into a snapshot base for workers.
USE_BASE_WIP="false"

# true: allow dirty tree without snapshot (workers start from BASE_REF only).
ALLOW_DIRTY="true"

# tmux session options.
TMUX_SESSION="codex-fleet"
KILL_EXISTING_SESSION="false"

# Codex executable and profiles.
CODEX_BIN="codex"
DIRECTOR_PROFILE="director"
WORKER_PROFILE="pair"

# If run command is used, wait this many seconds before sending director task.
DIRECTOR_INPUT_DELAY="2"

# Merge mode when integrating workers: merge or cherry-pick
MERGE_STRATEGY="merge"

# Backend default (tmux keeps teammates running even after launcher shell exits).
TEAMMATE_MODE="tmux"
TMUX_LAYOUT="split"
PERMISSION_MODE="default"
PLAN_MODE_REQUIRED="false"
AUTO_DELEGATE="true"
AUTO_KILL_DONE_WORKER_TMUX="true"

# Git selection (default: WSL git to avoid Windows conhost.exe overhead).
GIT_BIN="git"
CODEX_TEAM_GIT_BIN="$GIT_BIN"

# Optional Windows Git override (may spawn conhost.exe):
# GIT_BIN="/mnt/c/Program Files/Git/cmd/git.exe"
# CODEX_TEAM_GIT_BIN="$GIT_BIN"
# export PATH="/mnt/c/Program Files/Git/cmd:$PATH"
EOF
  chmod +x "$config_path" >/dev/null 2>&1 || true
}

cmd_setup() {
  local git_bin="$BOOT_GIT_BIN"
  require_cmd "$git_bin"

  local requested_repo="$REPO"
  local requested_repo_for_git
  requested_repo_for_git="$(repo_path_for_git_bin "$git_bin" "$requested_repo")"

  # setup targets the requested folder directly. If it has no local .git,
  # initialize an independent repository even when nested under another git root.
  if [[ ! -d "$requested_repo/.git" && ! -f "$requested_repo/.git" ]]; then
    if ! "$git_bin" -C "$requested_repo_for_git" init -b main >/dev/null 2>&1; then
      "$git_bin" -C "$requested_repo_for_git" init >/dev/null
      "$git_bin" -C "$requested_repo_for_git" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || true
    fi
    REPO="$requested_repo"
  else
    local repo_resolved
    repo_resolved="$("$git_bin" -C "$requested_repo_for_git" rev-parse --show-toplevel)"
    REPO="$(repo_path_from_git_bin "$git_bin" "$repo_resolved")"
  fi

  local repo_for_git
  repo_for_git="$(repo_path_for_git_bin "$git_bin" "$REPO")"

  ensure_git_identity_for_repo "$git_bin" "$REPO"

  if ! "$git_bin" -C "$repo_for_git" rev-parse --verify HEAD^{commit} >/dev/null 2>&1; then
    local has_entries
    has_entries="$(repo_has_non_git_entries "$REPO")"
    if [[ "$has_entries" == "false" ]]; then
      cat > "$REPO/README.md" <<'EOF'
# Repository Bootstrap

Initialized by codex-teams setup.
EOF
    fi
    "$git_bin" -C "$repo_for_git" add -A
    if "$git_bin" -C "$repo_for_git" diff --cached --quiet; then
      abort "setup could not create initial commit; no files to commit in $REPO"
    fi
    "$git_bin" -C "$repo_for_git" commit -m "chore: bootstrap repository for codex-teams" >/dev/null
  fi

  local head
  head="$("$git_bin" -C "$repo_for_git" rev-parse --short HEAD)"
  ensure_default_project_config "$REPO/.codex-multi-agent.config.sh"
  echo "setup complete"
  echo "- repo: $REPO"
  echo "- git: $git_bin"
  echo "- head: $head"
  echo "- config: $REPO/.codex-multi-agent.config.sh"
}

cmd_teamdelete() {
  load_config_or_defaults

  if [[ "$DELETE_FORCE" == "true" ]]; then
    force_terminate_runtime_agents
  fi

  if tmux has-session -t "$TMUX_SESSION" >/dev/null 2>&1; then
    if [[ "$DELETE_FORCE" == "true" ]]; then
      tmux kill-session -t "$TMUX_SESSION"
    else
      abort "tmux session is active ($TMUX_SESSION). stop it first or use --force"
    fi
  fi

  local force_arg=()
  if [[ "$DELETE_FORCE" == "true" ]]; then
    force_arg+=(--force)
  fi
  fs_cmd team-delete --repo "$REPO" --session "$TMUX_SESSION" "${force_arg[@]}"
  clear_viewer_bridge_if_session
}

bus_control_request() {
  local req_type="$1"
  local sender="$2"
  local recipient="$3"
  local body="$4"
  local summary="$5"
  local request_id="${6:-}"

  local out
  local args=(--db "$DB" control-request --room "$ROOM" --type "$req_type" --from "$sender" --to "$recipient" --body "$body" --summary "$summary")
  if [[ -n "$request_id" ]]; then
    args+=(--request-id "$request_id")
  fi
  out="$(python3 "$BUS" "${args[@]}")"
  printf '%s\n' "$out" | awk -F= '/^request_id=/{print $2; exit}'
}

bus_control_respond() {
  local request_id="$1"
  local sender="$2"
  local approve_flag="$3"
  local body="$4"

  if [[ "$approve_flag" == "true" ]]; then
    python3 "$BUS" --db "$DB" control-respond --request-id "$request_id" --from "$sender" --approve --body "$body" >/dev/null
  else
    python3 "$BUS" --db "$DB" control-respond --request-id "$request_id" --from "$sender" --reject --body "$body" >/dev/null
  fi
}

bus_lookup_request_fields() {
  local request_id="$1"
  python3 - "$DB" "$request_id" <<'PY'
import sqlite3
import sys
db, request_id = sys.argv[1], sys.argv[2]
try:
    conn = sqlite3.connect(db)
except Exception:
    print("||")
    raise SystemExit(0)
row = conn.execute(
    "select req_type, sender, recipient from control_requests where request_id=?",
    (request_id,),
).fetchone()
if not row:
    print("||")
else:
    print(f"{row[0]}|{row[1]}|{row[2]}")
PY
}

fs_control_request() {
  local req_type="$1"
  local sender="$2"
  local recipient="$3"
  local body="$4"
  local summary="$5"
  local request_id="${6:-}"

  local args=(control-request --repo "$REPO" --session "$TMUX_SESSION" --type "$req_type" --from "$sender" --to "$recipient" --body "$body" --summary "$summary")
  if [[ -n "$request_id" ]]; then
    args+=(--request-id "$request_id")
  fi
  local out
  out="$(fs_cmd "${args[@]}")"
  printf '%s\n' "$out" | awk -F= '/^request_id=/{print $2; exit}'
}

fs_control_respond() {
  local request_id="$1"
  local sender="$2"
  local approve_flag="$3"
  local body="$4"
  local recipient="${5:-}"
  local req_type="${6:-}"

  local args=(control-respond --repo "$REPO" --session "$TMUX_SESSION" --request-id "$request_id" --from "$sender" --body "$body")
  if [[ "$approve_flag" == "true" ]]; then
    args+=(--approve)
  else
    args+=(--reject)
  fi
  if [[ -n "$recipient" ]]; then
    args+=(--to "$recipient")
  fi
  if [[ -n "$req_type" ]]; then
    args+=(--req-type "$req_type")
  fi
  fs_cmd "${args[@]}" >/dev/null
}

fs_lookup_request_fields() {
  local request_id="$1"
  python3 - "$FS" "$REPO" "$TMUX_SESSION" "$request_id" <<'PY'
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
    print("||")
    raise SystemExit(0)
try:
    req = json.loads(proc.stdout)
except json.JSONDecodeError:
    print("||")
    raise SystemExit(0)
print(f"{req.get('req_type','')}|{req.get('sender','')}|{req.get('recipient','')}")
PY
}

cmd_sendmessage() {
  load_config_or_defaults
  init_bus_and_dirs

  if [[ -z "$MESSAGE_SENDER" ]]; then
    abort "sendmessage requires --from"
  fi

  local kind="$MESSAGE_KIND"
  local recipient="$MESSAGE_RECIPIENT"
  local body="$MESSAGE_CONTENT"
  local summary="$MESSAGE_SUMMARY"
  local msg_type="$MESSAGE_TYPE"

  if [[ -z "$body" ]]; then
    case "$msg_type" in
      shutdown_request) body="shutdown request" ;;
      shutdown_response|shutdown_approved|shutdown_rejected) body="shutdown response" ;;
      plan_approval_response) body="plan approval response" ;;
      permission_response) body="permission response" ;;
      mode_set_response) body="mode set response" ;;
      *)
        abort "sendmessage requires --content (or trailing message text)"
        ;;
    esac
  fi

  if [[ -z "$kind" ]]; then
    kind="$msg_type"
  fi

  if [[ "$msg_type" == "broadcast" ]]; then
    recipient="all"
  fi
  if [[ "$msg_type" == "message" && "$recipient" == "all" ]]; then
    msg_type="broadcast"
    if [[ -z "$MESSAGE_KIND" ]]; then
      kind="broadcast"
    fi
  fi

  case "$msg_type" in
    message|broadcast|task|question|answer|status|blocker|system)
      if [[ "$msg_type" != "broadcast" && -z "$recipient" ]]; then
        abort "sendmessage requires --to for type=$msg_type"
      fi
      python3 "$BUS" --db "$DB" send --room "$ROOM" --from "$MESSAGE_SENDER" --to "$recipient" --kind "$kind" --body "$body" --meta "$MESSAGE_META" >/dev/null
      fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type "$msg_type" --from "$MESSAGE_SENDER" --recipient "$recipient" --content "$body" --summary "$summary" --meta "$MESSAGE_META" >/dev/null
      ;;

    shutdown_request|plan_approval_request|permission_request|mode_set_request)
      if [[ -z "$recipient" ]]; then
        abort "sendmessage requires --to for type=$msg_type"
      fi
      local req_type="$msg_type"
      req_type="${req_type%_request}"
      local rid="$MESSAGE_REQUEST_ID"
      if [[ -z "$rid" ]]; then
        rid="$(python3 - <<'PY'
import uuid
print(uuid.uuid4().hex[:12])
PY
)"
      fi
      if [[ -f "$DB" ]]; then
        local bus_rid
        bus_rid="$(bus_control_request "$req_type" "$MESSAGE_SENDER" "$recipient" "$body" "$summary" "$rid" || true)"
        if [[ -n "$bus_rid" ]]; then
          rid="$bus_rid"
        fi
      fi
      local fs_rid
      fs_rid="$(fs_control_request "$req_type" "$MESSAGE_SENDER" "$recipient" "$body" "$summary" "$rid" || true)"
      if [[ -n "$fs_rid" ]]; then
        rid="$fs_rid"
      else
        local fs_req_info
        fs_req_info="$(fs_lookup_request_fields "$rid" || true)"
        if [[ "$fs_req_info" == "||" || -z "$fs_req_info" ]]; then
          fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type "$msg_type" --from "$MESSAGE_SENDER" --recipient "$recipient" --content "$body" --summary "$summary" --request-id "$rid" --meta "$MESSAGE_META" >/dev/null
        fi
      fi
      echo "request_id=$rid"
      ;;

    shutdown_response|shutdown_approved|shutdown_rejected|plan_approval_response|permission_response|mode_set_response)
      if [[ -z "$MESSAGE_REQUEST_ID" ]]; then
        abort "sendmessage requires --request-id for type=$msg_type"
      fi
      if [[ "$msg_type" == "shutdown_approved" ]]; then
        MESSAGE_APPROVE="true"
        msg_type="shutdown_response"
      elif [[ "$msg_type" == "shutdown_rejected" ]]; then
        MESSAGE_APPROVE="false"
        msg_type="shutdown_response"
      fi
      if [[ -z "$MESSAGE_APPROVE" ]]; then
        abort "sendmessage requires --approve or --reject for type=$msg_type"
      fi
      local response_body="$body"
      if [[ -f "$DB" ]]; then
        bus_control_respond "$MESSAGE_REQUEST_ID" "$MESSAGE_SENDER" "$MESSAGE_APPROVE" "$response_body"
      fi

      local req_info req_type req_sender req_target
      req_info="$(bus_lookup_request_fields "$MESSAGE_REQUEST_ID" || true)"
      if [[ "$req_info" == "||" || -z "$req_info" ]]; then
        req_info="$(fs_lookup_request_fields "$MESSAGE_REQUEST_ID" || true)"
      fi
      req_type="${req_info%%|*}"
      local req_tail="${req_info#*|}"
      req_sender="${req_tail%%|*}"
      req_target="${req_info##*|}"

      if [[ -z "$recipient" ]]; then
        if [[ -n "$req_sender" ]]; then
          recipient="$req_sender"
        else
          recipient="$TEAM_LEAD_NAME"
        fi
      fi

      local response_req_type="$req_type"
      if [[ -z "$response_req_type" ]]; then
        response_req_type="$msg_type"
        response_req_type="${response_req_type%_response}"
      fi
      fs_control_respond "$MESSAGE_REQUEST_ID" "$MESSAGE_SENDER" "$MESSAGE_APPROVE" "$response_body" "$recipient" "$response_req_type" || \
        fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type "$msg_type" --from "$MESSAGE_SENDER" --recipient "$recipient" --content "$response_body" --summary "$summary" --request-id "$MESSAGE_REQUEST_ID" --approve "$MESSAGE_APPROVE" --meta "$MESSAGE_META" >/dev/null

      if [[ "$msg_type" == "shutdown_response" && "$MESSAGE_APPROVE" == "true" ]]; then
        local shutdown_target="$req_target"
        if [[ -z "$shutdown_target" ]]; then
          shutdown_target="$MESSAGE_RECIPIENT"
        fi
        if [[ -n "$shutdown_target" ]]; then
          apply_shutdown_target "$shutdown_target"
        fi
      fi
      ;;

    *)
      abort "unsupported --type: $msg_type"
      ;;
  esac
}

parse_args() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi

  COMMAND="$1"
  shift

  case "$COMMAND" in
    init|setup|run|up|status|merge|teamcreate|teamdelete|sendmessage) ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      abort "unsupported command: $COMMAND"
      ;;
  esac

  require_windows_wsl_runtime

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
      --auto-delegate)
        AUTO_DELEGATE="true"
        AUTO_DELEGATE_OVERRIDE="true"
        shift
        ;;
      --no-auto-delegate)
        AUTO_DELEGATE="false"
        AUTO_DELEGATE_OVERRIDE="false"
        shift
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
      --git-bin)
        GIT_BIN_OVERRIDE="$2"
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
      --team-name)
        TEAM_NAME_OVERRIDE="$2"
        shift 2
        ;;
      --description)
        TEAM_DESCRIPTION="$2"
        shift 2
        ;;
      --lead-name)
        TEAM_LEAD_NAME="$2"
        shift 2
        ;;
      --agent-type)
        LEAD_AGENT_TYPE="$2"
        shift 2
        ;;
      --replace)
        TEAMCREATE_REPLACE="true"
        shift
        ;;
      --force)
        DELETE_FORCE="true"
        shift
        ;;
      --teammate-mode)
        TEAMMATE_MODE="$2"
        TEAMMATE_MODE_OVERRIDE="$2"
        shift 2
        ;;
      --tmux-layout)
        TMUX_LAYOUT="$2"
        TMUX_LAYOUT_OVERRIDE="$2"
        shift 2
        ;;
      --permission-mode)
        PERMISSION_MODE="$2"
        PERMISSION_MODE_OVERRIDE="$2"
        shift 2
        ;;
      --plan-mode-required)
        PLAN_MODE_REQUIRED="true"
        PLAN_MODE_REQUIRED_OVERRIDE="true"
        shift
        ;;
      --type)
        MESSAGE_TYPE="$2"
        shift 2
        ;;
      --from)
        MESSAGE_SENDER="$2"
        shift 2
        ;;
      --to)
        MESSAGE_RECIPIENT="$2"
        shift 2
        ;;
      --content)
        MESSAGE_CONTENT="$2"
        shift 2
        ;;
      --summary)
        MESSAGE_SUMMARY="$2"
        shift 2
        ;;
      --kind)
        MESSAGE_KIND="$2"
        shift 2
        ;;
      --meta)
        MESSAGE_META="$2"
        shift 2
        ;;
      --request-id)
        MESSAGE_REQUEST_ID="$2"
        shift 2
        ;;
      --approve)
        if [[ "$MESSAGE_APPROVE" == "false" ]]; then
          abort "--approve and --reject are mutually exclusive"
        fi
        MESSAGE_APPROVE="true"
        shift
        ;;
      --reject)
        if [[ "$MESSAGE_APPROVE" == "true" ]]; then
          abort "--approve and --reject are mutually exclusive"
        fi
        MESSAGE_APPROVE="false"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        if [[ "$COMMAND" == "sendmessage" ]]; then
          MESSAGE_CONTENT="$*"
          break
        fi
        abort "unexpected trailing args"
        ;;
      *)
        if [[ "$COMMAND" == "sendmessage" ]]; then
          if [[ -z "$MESSAGE_CONTENT" ]]; then
            MESSAGE_CONTENT="$1"
          else
            MESSAGE_CONTENT="$MESSAGE_CONTENT $1"
          fi
          shift
        else
          abort "unknown arg: $1"
        fi
        ;;
    esac
  done

  REPO="$(normalize_input_path_for_wsl "$REPO")"
  if [[ -n "$CONFIG" ]]; then
    CONFIG="$(normalize_input_path_for_wsl "$CONFIG")"
  fi
  if [[ -n "$GIT_BIN_OVERRIDE" ]]; then
    GIT_BIN_OVERRIDE="$(normalize_git_bin_path "$GIT_BIN_OVERRIDE")"
  fi

  REPO="$(cd "$REPO" && pwd)"
  require_windows_repo_path "$REPO"
  BOOT_GIT_BIN="$(resolve_boot_git_bin "$REPO")"
  BOOT_GIT_BIN="$(require_subprocess_executable "$BOOT_GIT_BIN" "boot git binary")"
  if [[ "$COMMAND" != "setup" ]]; then
    local repo_for_boot_git
    repo_for_boot_git="$(repo_path_for_git_bin "$BOOT_GIT_BIN" "$REPO")"
    if ! "$BOOT_GIT_BIN" -C "$repo_for_boot_git" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      abort "not a git repository: $REPO (run: codex-teams setup --repo \"$REPO\")"
    fi
    local repo_resolved
    repo_resolved="$("$BOOT_GIT_BIN" -C "$repo_for_boot_git" rev-parse --show-toplevel)"
    REPO="$(repo_path_from_git_bin "$BOOT_GIT_BIN" "$repo_resolved")"
    require_windows_repo_path "$REPO"
  fi

  if [[ -z "$CONFIG" ]]; then
    CONFIG="$REPO/.codex-multi-agent.config.sh"
  else
    CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
  fi

  if ! [[ "$DASHBOARD_LINES" =~ ^[0-9]+$ ]] || [[ "$DASHBOARD_LINES" -lt 1 ]]; then
    abort "--dashboard-lines must be >= 1"
  fi
  if ! [[ "$DASHBOARD_MESSAGES" =~ ^[0-9]+$ ]] || [[ "$DASHBOARD_MESSAGES" -lt 1 ]]; then
    abort "--dashboard-messages must be >= 1"
  fi
  case "$TEAMMATE_MODE" in auto|tmux|in-process|in-process-shared) ;; *) abort "--teammate-mode must be auto|tmux|in-process|in-process-shared" ;; esac
  case "$TMUX_LAYOUT" in split|window) ;; *) abort "--tmux-layout must be split|window" ;; esac
}

main() {
  parse_args "$@"

  case "$COMMAND" in
    setup|teamcreate|teamdelete|sendmessage|run|up|status)
      require_teams_enabled
      ;;
    *)
      ;;
  esac

  case "$COMMAND" in
    init)
      exec "$LEGACY_SCRIPT" init --repo "$REPO"
      ;;

    setup)
      cmd_setup
      ;;

    merge)
      exec "$LEGACY_SCRIPT" merge --repo "$REPO" --config "$CONFIG" --room "$ROOM"
      ;;

    teamcreate)
      cmd_teamcreate
      ;;

    teamdelete)
      cmd_teamdelete
      ;;

    sendmessage)
      cmd_sendmessage
      ;;

    run|up)
      load_config_or_defaults
      run_swarm
      ;;

    status)
      load_config_or_defaults
      run_status
      ;;

    *)
      abort "unsupported command: $COMMAND"
      ;;
  esac
}

main "$@"
