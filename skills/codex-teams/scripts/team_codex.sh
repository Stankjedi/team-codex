#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS="$SCRIPT_DIR/team_bus.py"
FS="$SCRIPT_DIR/team_fs.py"
STATUS="$SCRIPT_DIR/team_status.sh"
MAILBOX="$SCRIPT_DIR/team_mailbox.sh"
CONTROL="$SCRIPT_DIR/team_control.sh"
MODEL_RESOLVER="$SCRIPT_DIR/resolve_model.py"
INPROCESS_HUB="$SCRIPT_DIR/team_inprocess_hub.py"
VIEWER_BRIDGE_FILE=".codex-teams/.viewer-session.json"
WINDOWS_GIT_EXE_PATH="/mnt/c/Program Files/Git/cmd/git.exe"

COMMAND=""
REPO="$(pwd)"
CONFIG=""
TASK=""
ROOM="main"
WORKERS=""

MODEL=""
DIRECTOR_MODEL=""
WORKER_MODEL=""
REVIEWER_MODEL=""
DIRECTOR_PROFILE_OVERRIDE=""
WORKER_PROFILE_OVERRIDE=""
REVIEWER_PROFILE_OVERRIDE=""
REVIEWER_NAME_OVERRIDE=""
SESSION_OVERRIDE=""

TEAM_NAME_OVERRIDE=""
TEAM_DESCRIPTION=""
TEAMCREATE_REPLACE="false"
DELETE_FORCE="false"

TEAM_LEAD_NAME="lead"
LEAD_AGENT_TYPE="team-lead"
REVIEWER_AGENT_NAME="reviewer-1"
TEAMMATE_MODE="in-process-shared"
PERMISSION_MODE="default"
PLAN_MODE_REQUIRED="false"
TEAMMATE_MODE_OVERRIDE=""
PERMISSION_MODE_OVERRIDE=""
PLAN_MODE_REQUIRED_OVERRIDE=""
AUTO_DELEGATE="true"
AUTO_DELEGATE_OVERRIDE=""
INPROCESS_POLL_MS="250"
INPROCESS_IDLE_MS="12000"
# in-process-shared startup 안정성 확인 구간(초).
INPROCESS_SHARED_STABILIZE_SEC="12"
# startup 실패 시 재시도 횟수(총 시도 횟수 = retries + 1).
INPROCESS_SHARED_START_RETRIES="1"
# 동일 세션/레포 병렬 제어 충돌 방지 lock 대기 시간(초).
SESSION_LOCK_WAIT_SEC="20"
DEPS_INSTALL="false"

MESSAGE_TYPE="message"
MESSAGE_SENDER=""
MESSAGE_RECIPIENT=""
MESSAGE_CONTENT=""
MESSAGE_SUMMARY=""
MESSAGE_KIND=""
MESSAGE_META="{}"
MESSAGE_REQUEST_ID=""
MESSAGE_APPROVE=""

LEAD_MODEL=""
LEAD_PROFILE=""
REVIEWER_PROFILE=""
GIT_BIN_OVERRIDE=""
GIT_BIN=""
BOOT_GIT_BIN="git"
WORKER_COUNT="3"
TEAM_ROLE_SUMMARY=""
NORMALIZED_TEAMMATE_MODE=""
LEAD_WORKTREE=""
INPROCESS_HUB_AGENT="inprocess-hub"
AUTO_DEP_PM=""
AUTO_DEP_UPDATED="false"
LOCK_TRAP_INSTALLED="false"
HELD_LOCK_MODE=""
HELD_LOCK_PATH=""
HELD_LOCK_FD=""

declare -a TEAM_AGENT_NAMES=()
declare -A TEAM_AGENT_ROLE=()
declare -A TEAM_AGENT_PROFILE=()
declare -A TEAM_AGENT_MODEL=()
declare -A TEAM_AGENT_PERMISSION=()
declare -A BOOT_PROMPT_BY_AGENT=()

usage() {
  cat <<'USAGE'
Codex Teams (Windows+WSL only, filesystem mailbox + bus + in-process-shared runtime)

Usage:
  team_codex.sh <command> [options]

Commands:
  deps                    Check/install runtime dependencies (separate from setup)
  init                    Initialize project config for codex-teams
  setup                   Prepare repository (git init + initial commit) for codex-teams
  run                     TeamCreate + spawn teammates + inject task
  up                      Same as run without task injection
  status                  Show runtime/team/bus status
  merge                   Merge worker branches into current branch
  teamcreate              Create team config/inboxes/state
  teamdelete              Delete team artifacts
  sendmessage             Send typed team message (Claude Teams-style union)

Platform policy:
  - Windows host + WSL environment only
  - repository path must be under /mnt/<drive>/...
  - fixed team topology: lead(external) + reviewer-1 + worker-1 + worker-2 + worker-3

Common options:
  --repo PATH             Target repo path (default: current directory, supports C:\... auto-convert)
  --config PATH           Config path (default: <repo>/.codex-multi-agent.config.sh, supports C:\... auto-convert)
  --room NAME             Team bus room (default: main)
  --session NAME          Session/team name override
  --workers N             Worker count override (fixed policy: only `3` is accepted)
  --director-profile NAME Lead profile override (legacy flag name)
  --worker-profile NAME   Worker profile override
  --reviewer-profile NAME Reviewer profile override
  --model MODEL           Set model for all roles
  --director-model MODEL  Lead model override (legacy flag name)
  --worker-model MODEL    Worker model override
  --reviewer-model MODEL  Reviewer model override
  --git-bin PATH          Git binary override (default: git; supports C:\... auto-convert)

Backend options:
  --teammate-mode MODE    in-process-shared (auto is accepted as alias)
  --permission-mode MODE  default|acceptEdits|bypassPermissions|plan|delegate|dontAsk
  --plan-mode-required    Mark teammate config as plan-mode required
  config: INPROCESS_POLL_MS=250 (hub mailbox poll interval, ms)
  config: INPROCESS_IDLE_MS=12000 (idle status cadence, ms)
  config: INPROCESS_SHARED_STABILIZE_SEC=12 (in-process-shared startup stability window, sec)
  config: INPROCESS_SHARED_START_RETRIES=1 (in-process-shared startup retry count)
  config: SESSION_LOCK_WAIT_SEC=20 (session/repo lock wait timeout, sec)
  lead runtime: external (current codex IDE/session)

run/up options:
  --task TEXT             Initial task text (required for run)
  --auto-delegate         Auto-delegate initial task to role agents (default)
  --no-auto-delegate      Disable automatic worker delegation

init/teamcreate/teamdelete options:
  --team-name NAME        Team name override (default: session)
  --description TEXT      Team description
  --lead-name NAME        Team lead name (default: lead)
  --reviewer-name NAME    Reviewer agent name (default: reviewer-1)
  --agent-type TYPE       Team lead agent type (default: team-lead)
  --force                 Overwrite existing config on init / force delete on teamdelete
  --replace               Overwrite existing team config on teamcreate

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

deps options:
  --install               Attempt to install missing dependencies via package manager

Examples:
  team_codex.sh deps
  team_codex.sh deps --install
  team_codex.sh setup --repo .
  team_codex.sh run --task "Fix flaky tests" --teammate-mode in-process-shared
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

now_utc_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

release_command_lock() {
  if [[ -z "$HELD_LOCK_PATH" ]]; then
    return 0
  fi

  case "$HELD_LOCK_MODE" in
    flock)
      if [[ -n "$HELD_LOCK_FD" ]]; then
        flock -u "$HELD_LOCK_FD" >/dev/null 2>&1 || true
        eval "exec ${HELD_LOCK_FD}>&-"
      fi
      ;;
    mkdir)
      rm -rf "$HELD_LOCK_PATH" >/dev/null 2>&1 || true
      ;;
    *)
      ;;
  esac

  HELD_LOCK_MODE=""
  HELD_LOCK_PATH=""
  HELD_LOCK_FD=""
}

ensure_lock_cleanup_trap() {
  if [[ "$LOCK_TRAP_INSTALLED" == "true" ]]; then
    return 0
  fi
  trap 'release_command_lock' EXIT
  LOCK_TRAP_INSTALLED="true"
}

acquire_lock_with_flock() {
  local lock_path="$1"
  local wait_sec="$2"
  local lock_label="$3"
  local fd

  exec {fd}>"$lock_path"
  if ! flock -w "$wait_sec" "$fd"; then
    eval "exec ${fd}>&-"
    return 1
  fi

  HELD_LOCK_MODE="flock"
  HELD_LOCK_PATH="$lock_path"
  HELD_LOCK_FD="$fd"
  echo "$(now_utc_iso) lock-acquired method=flock label=$lock_label pid=$$" >> "${lock_path}.events.log" 2>/dev/null || true
  return 0
}

acquire_lock_with_mkdir() {
  local lock_path="$1"
  local wait_sec="$2"
  local lock_label="$3"
  local lock_dir="${lock_path}.dirlock"
  local deadline=$((SECONDS + wait_sec))

  while true; do
    if mkdir "$lock_dir" >/dev/null 2>&1; then
      printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || true
      HELD_LOCK_MODE="mkdir"
      HELD_LOCK_PATH="$lock_dir"
      echo "$(now_utc_iso) lock-acquired method=mkdir label=$lock_label pid=$$" >> "${lock_path}.events.log" 2>/dev/null || true
      return 0
    fi

    local owner_pid=""
    if [[ -f "$lock_dir/pid" ]]; then
      owner_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    fi
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" >/dev/null 2>&1; then
      rm -rf "$lock_dir" >/dev/null 2>&1 || true
      continue
    fi

    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.2
  done
}

acquire_command_lock() {
  local lock_path="$1"
  local lock_label="$2"
  local wait_sec="$3"

  mkdir -p "$(dirname "$lock_path")"
  ensure_lock_cleanup_trap

  if [[ -n "$HELD_LOCK_PATH" ]]; then
    case "$HELD_LOCK_MODE" in
      flock)
        if [[ "$HELD_LOCK_PATH" == "$lock_path" ]]; then
          return 0
        fi
        ;;
      mkdir)
        if [[ "$HELD_LOCK_PATH" == "${lock_path}.dirlock" ]]; then
          return 0
        fi
        ;;
      *)
        ;;
    esac
    abort "internal lock state mismatch while requesting $lock_label lock"
  fi

  if command -v flock >/dev/null 2>&1; then
    if acquire_lock_with_flock "$lock_path" "$wait_sec" "$lock_label"; then
      return 0
    fi
  fi

  if acquire_lock_with_mkdir "$lock_path" "$wait_sec" "$lock_label"; then
    return 0
  fi

  abort "timed out waiting for $lock_label lock (${wait_sec}s): $lock_path"
}

acquire_repo_lock() {
  local lock_path="$REPO/.codex-teams/.repo.lock"
  acquire_command_lock "$lock_path" "repo" "$SESSION_LOCK_WAIT_SEC"
}

acquire_session_lock() {
  local lock_path="$REPO/.codex-teams/$TMUX_SESSION/.session.lock"
  acquire_command_lock "$lock_path" "session=$TMUX_SESSION" "$SESSION_LOCK_WAIT_SEC"
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' "apt-get"
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    printf '%s\n' "dnf"
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    printf '%s\n' "yum"
    return 0
  fi
  if command -v pacman >/dev/null 2>&1; then
    printf '%s\n' "pacman"
    return 0
  fi
  if command -v zypper >/dev/null 2>&1; then
    printf '%s\n' "zypper"
    return 0
  fi
  if command -v apk >/dev/null 2>&1; then
    printf '%s\n' "apk"
    return 0
  fi
  return 1
}

run_with_privilege() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
    return $?
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return $?
  fi
  return 127
}

package_name_for_command() {
  local pm="$1"
  local cmd="$2"
  case "$cmd" in
    git)
      printf '%s\n' "git"
      ;;
    python3)
      printf '%s\n' "python3"
      ;;
    sqlite3)
      case "$pm" in
        apt-get)
          printf '%s\n' "sqlite3"
          ;;
        dnf|yum|pacman|zypper|apk)
          printf '%s\n' "sqlite"
          ;;
        *)
          printf '%s\n' "sqlite3"
          ;;
      esac
      ;;
    wslpath)
      case "$pm" in
        apt-get)
          printf '%s\n' "wslu"
          ;;
        *)
          printf '%s\n' ""
          ;;
      esac
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

install_package_with_manager() {
  local pm="$1"
  local pkg="$2"
  case "$pm" in
    apt-get)
      if [[ "$AUTO_DEP_UPDATED" != "true" ]]; then
        run_with_privilege apt-get update -y
        AUTO_DEP_UPDATED="true"
      fi
      run_with_privilege apt-get install -y --no-install-recommends "$pkg"
      ;;
    dnf)
      run_with_privilege dnf install -y "$pkg"
      ;;
    yum)
      run_with_privilege yum install -y "$pkg"
      ;;
    pacman)
      run_with_privilege pacman -Sy --noconfirm --needed "$pkg"
      ;;
    zypper)
      run_with_privilege zypper --non-interactive install -y "$pkg"
      ;;
    apk)
      run_with_privilege apk add --no-cache "$pkg"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_dependency_command() {
  local cmd="$1"
  local action="${2:-check}"

  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$action" != "install" ]]; then
    return 1
  fi

  if [[ -z "$AUTO_DEP_PM" ]]; then
    AUTO_DEP_PM="$(detect_package_manager || true)"
  fi
  if [[ -z "$AUTO_DEP_PM" ]]; then
    return 1
  fi

  local pkg
  pkg="$(package_name_for_command "$AUTO_DEP_PM" "$cmd")"
  if [[ -z "$pkg" ]]; then
    return 1
  fi

  echo "missing dependency '$cmd'. attempting install via $AUTO_DEP_PM (package: $pkg) ..."
  if ! install_package_with_manager "$AUTO_DEP_PM" "$pkg"; then
    return 1
  fi

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "installed dependency '$cmd' successfully."
    return 0
  fi

  return 1
}

dependency_status_line() {
  local cmd="$1"
  local required="${2:-required}"
  local install_mode="${3:-false}"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[ok] $cmd -> $(command -v "$cmd")"
    return 0
  fi

  if [[ "$install_mode" == "true" ]]; then
    if ensure_dependency_command "$cmd" "install"; then
      echo "[installed] $cmd -> $(command -v "$cmd")"
      return 0
    fi
  fi

  local severity="optional"
  if [[ "$required" == "required" ]]; then
    severity="required"
  fi
  echo "[missing] $cmd ($severity)"

  if [[ "$required" == "required" ]]; then
    return 2
  fi
  return 1
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

require_windows_wsl_runtime_base() {
  if ! is_wsl_environment; then
    abort "codex-teams is Windows+WSL only. Run this command inside WSL on a Windows host."
  fi
  if [[ ! -d "/mnt/c" ]]; then
    abort "missing Windows mount (/mnt/c). ensure WSL is configured with Windows drive mounts enabled."
  fi
}

require_windows_wsl_runtime() {
  require_windows_wsl_runtime_base
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

resolve_teammate_backend() {
  local requested="${1:-in-process-shared}"
  case "$requested" in
    in-process-shared|auto)
      printf '%s\n' "in-process-shared"
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

validate_session_name() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    abort "session is required"
  fi
  if [[ "$raw" == *"/"* || "$raw" == *"\\"* ]]; then
    abort "invalid session name '$raw' (path separators are not allowed)"
  fi
  if [[ "$raw" == "." || "$raw" == ".." || "$raw" == *".."* ]]; then
    abort "invalid session name '$raw'"
  fi
  if ! [[ "$raw" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    abort "invalid session name '$raw' (allowed: [A-Za-z0-9._-], max 128, starts with alnum)"
  fi
  printf '%s\n' "$raw"
}

is_teams_enabled() {
  local feature_flag="${CODEX_EXPERIMENTAL_AGENT_TEAMS:-${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}}"
  local gate_flag="${CODEX_TEAMS_GATE_TENGU_AMBER_FLINT:-${CLAUDE_CODE_STATSIG_TENGU_AMBER_FLINT:-}}"
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
  local layout="${2:-shared}"
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

role_from_agent_name() {
  local agent="$1"
  case "$agent" in
    "$TEAM_LEAD_NAME") printf '%s\n' "lead" ;;
    "$REVIEWER_AGENT_NAME") printf '%s\n' "reviewer" ;;
    reviewer-*) printf '%s\n' "reviewer" ;;
    worker-*) printf '%s\n' "worker" ;;
    *) printf '%s\n' "worker" ;;
  esac
}

role_default_profile() {
  local role="$1"
  case "$role" in
    lead) printf '%s\n' "$LEAD_PROFILE" ;;
    reviewer) printf '%s\n' "$REVIEWER_PROFILE" ;;
    worker) printf '%s\n' "$WORKER_PROFILE" ;;
    *) printf '%s\n' "$WORKER_PROFILE" ;;
  esac
}

role_default_model() {
  local role="$1"
  case "$role" in
    lead) printf '%s\n' "$LEAD_MODEL" ;;
    reviewer) printf '%s\n' "$REVIEWER_MODEL" ;;
    worker) printf '%s\n' "$WORKER_MODEL" ;;
    *) printf '%s\n' "$WORKER_MODEL" ;;
  esac
}

role_default_permission_mode() {
  local role="$1"
  case "$role" in
    reviewer) printf '%s\n' "plan" ;;
    *) printf '%s\n' "$PERMISSION_MODE" ;;
  esac
}

role_peer_name() {
  local agent="$1"
  case "$agent" in
    worker-1) printf '%s\n' "worker-2" ;;
    worker-2) printf '%s\n' "worker-3" ;;
    worker-3) printf '%s\n' "worker-1" ;;
    "$REVIEWER_AGENT_NAME") printf '%s\n' "$TEAM_LEAD_NAME" ;;
    *) printf '%s\n' "$TEAM_LEAD_NAME" ;;
  esac
}

derive_role_team_shape() {
  if [[ "$COUNT" != "3" ]]; then
    echo "info: fixed worker policy active (forcing COUNT=3; requested: $COUNT)" >&2
  fi
  COUNT="3"
  WORKER_COUNT="3"
  TEAM_AGENT_NAMES=()
  TEAM_AGENT_ROLE=()
  TEAM_AGENT_PROFILE=()
  TEAM_AGENT_MODEL=()
  TEAM_AGENT_PERMISSION=()
  BOOT_PROMPT_BY_AGENT=()

  TEAM_AGENT_NAMES+=("$REVIEWER_AGENT_NAME")
  TEAM_AGENT_ROLE["$REVIEWER_AGENT_NAME"]="reviewer"
  TEAM_AGENT_PROFILE["$REVIEWER_AGENT_NAME"]="$(role_default_profile reviewer)"
  TEAM_AGENT_MODEL["$REVIEWER_AGENT_NAME"]="$(role_default_model reviewer)"
  TEAM_AGENT_PERMISSION["$REVIEWER_AGENT_NAME"]="$(role_default_permission_mode reviewer)"

  local i agent role
  for i in $(seq 1 "$WORKER_COUNT"); do
    agent="worker-$i"
    role="worker"
    TEAM_AGENT_NAMES+=("$agent")
    TEAM_AGENT_ROLE["$agent"]="$role"
    TEAM_AGENT_PROFILE["$agent"]="$(role_default_profile "$role")"
    TEAM_AGENT_MODEL["$agent"]="$(role_default_model "$role")"
    TEAM_AGENT_PERMISSION["$agent"]="$(role_default_permission_mode "$role")"
  done

  TEAM_ROLE_SUMMARY="lead=1 reviewer=1 worker=$WORKER_COUNT"
}

fs_cmd() {
  python3 "$FS" "$@"
}

load_config_or_defaults() {
  COUNT="3"
  PREFIX="worker"
  WORKTREES_DIR=".worktrees"
  BASE_REF="HEAD"
  USE_BASE_WIP="false"
  ALLOW_DIRTY="true"
  TMUX_SESSION="codex-fleet"
  KILL_EXISTING_SESSION="false"
  CODEX_BIN="codex"
  DIRECTOR_PROFILE="xhigh"
  WORKER_PROFILE="high"
  REVIEWER_PROFILE="xhigh"
  LEAD_PROFILE=""
  LEAD_MODEL="gpt-5.3-codex"
  WORKER_MODEL="gpt-5.3-codex"
  REVIEWER_MODEL="gpt-5.3-codex-spark"
  MERGE_STRATEGY="merge"
  TEAMMATE_MODE="in-process-shared"
  PERMISSION_MODE="default"
  PLAN_MODE_REQUIRED="false"
  AUTO_DELEGATE="true"
  INPROCESS_POLL_MS="250"
  INPROCESS_IDLE_MS="12000"
  INPROCESS_SHARED_STABILIZE_SEC="12"
  INPROCESS_SHARED_START_RETRIES="1"
  SESSION_LOCK_WAIT_SEC="20"
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

  if [[ -n "${REVIEWER_NAME:-}" ]]; then
    REVIEWER_AGENT_NAME="$REVIEWER_NAME"
  fi
  if [[ -n "$REVIEWER_NAME_OVERRIDE" ]]; then
    REVIEWER_AGENT_NAME="$REVIEWER_NAME_OVERRIDE"
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
    LEAD_PROFILE="$DIRECTOR_PROFILE_OVERRIDE"
  fi
  if [[ -n "$WORKER_PROFILE_OVERRIDE" ]]; then
    WORKER_PROFILE="$WORKER_PROFILE_OVERRIDE"
  fi
  if [[ -n "$REVIEWER_PROFILE_OVERRIDE" ]]; then
    REVIEWER_PROFILE="$REVIEWER_PROFILE_OVERRIDE"
  fi
  if [[ -n "$SESSION_OVERRIDE" ]]; then
    TMUX_SESSION="$SESSION_OVERRIDE"
  fi
  if [[ -n "$TEAMMATE_MODE_OVERRIDE" ]]; then
    TEAMMATE_MODE="$TEAMMATE_MODE_OVERRIDE"
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
  TMUX_SESSION="$(validate_session_name "$TMUX_SESSION")"
  if [[ -z "$REVIEWER_AGENT_NAME" ]]; then
    abort "reviewer agent name is required"
  fi
  if [[ "$REVIEWER_AGENT_NAME" == "$TEAM_LEAD_NAME" ]]; then
    abort "reviewer agent name must differ from lead name"
  fi
  if ! [[ "$REVIEWER_AGENT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    abort "invalid reviewer name '$REVIEWER_AGENT_NAME' (allowed: [A-Za-z0-9._-], max 128, starts with alnum)"
  fi
  GIT_BIN="$(normalize_git_bin_path "$GIT_BIN")"

  if [[ -z "$LEAD_PROFILE" ]]; then
    LEAD_PROFILE="$DIRECTOR_PROFILE"
  fi
  if [[ -n "$WORKERS" ]]; then
    if [[ "$WORKERS" != "3" ]]; then
      abort "--workers is fixed at 3 in external-lead + reviewer topology"
    fi
    COUNT="3"
  fi

  if [[ -n "$MODEL" ]]; then
    DIRECTOR_MODEL="$MODEL"
    WORKER_MODEL="$MODEL"
    LEAD_MODEL="$MODEL"
    REVIEWER_MODEL="$MODEL"
  fi

  if [[ -n "$DIRECTOR_MODEL" && -z "$LEAD_MODEL" ]]; then
    LEAD_MODEL="$DIRECTOR_MODEL"
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
  if [[ -z "$REVIEWER_MODEL" ]]; then
    REVIEWER_MODEL="$(python3 "$MODEL_RESOLVER" --project-root "$REPO" --role reviewer --profile "$REVIEWER_PROFILE" 2>/dev/null || true)"
  fi

  if [[ -z "$LEAD_MODEL" ]]; then
    LEAD_MODEL="$DIRECTOR_MODEL"
  fi
  if [[ -z "$REVIEWER_MODEL" ]]; then
    REVIEWER_MODEL="$WORKER_MODEL"
  fi

  if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    abort "worker count must be numeric"
  fi
  case "$USE_BASE_WIP" in true|false) ;; *) abort "USE_BASE_WIP must be true/false" ;; esac
  case "$ALLOW_DIRTY" in true|false) ;; *) abort "ALLOW_DIRTY must be true/false" ;; esac
  case "$KILL_EXISTING_SESSION" in true|false) ;; *) abort "KILL_EXISTING_SESSION must be true/false" ;; esac
  if [[ "$TEAMMATE_MODE" != "auto" && "$TEAMMATE_MODE" != "in-process-shared" ]]; then
    echo "info: unsupported TEAMMATE_MODE=$TEAMMATE_MODE; forcing in-process-shared" >&2
    TEAMMATE_MODE="in-process-shared"
  fi
  case "$TEAMMATE_MODE" in auto|in-process-shared) ;; *) abort "TEAMMATE_MODE must be in-process-shared (auto alias allowed)" ;; esac
  if [[ "$TEAMMATE_MODE" == "auto" ]]; then
    TEAMMATE_MODE="in-process-shared"
  fi
  case "$MERGE_STRATEGY" in merge|cherry-pick) ;; *) abort "MERGE_STRATEGY must be merge|cherry-pick" ;; esac
  case "$PLAN_MODE_REQUIRED" in true|false) ;; *) abort "PLAN_MODE_REQUIRED must be true|false" ;; esac
  case "$AUTO_DELEGATE" in true|false) ;; *) abort "AUTO_DELEGATE must be true|false" ;; esac
  if ! [[ "$INPROCESS_POLL_MS" =~ ^[0-9]+$ ]] || [[ "$INPROCESS_POLL_MS" -lt 100 ]]; then
    abort "INPROCESS_POLL_MS must be numeric and >= 100"
  fi
  if ! [[ "$INPROCESS_IDLE_MS" =~ ^[0-9]+$ ]] || [[ "$INPROCESS_IDLE_MS" -lt 1000 ]]; then
    abort "INPROCESS_IDLE_MS must be numeric and >= 1000"
  fi
  if ! [[ "$INPROCESS_SHARED_STABILIZE_SEC" =~ ^[0-9]+$ ]] || [[ "$INPROCESS_SHARED_STABILIZE_SEC" -lt 1 ]]; then
    abort "INPROCESS_SHARED_STABILIZE_SEC must be numeric and >= 1"
  fi
  if ! [[ "$INPROCESS_SHARED_START_RETRIES" =~ ^[0-9]+$ ]]; then
    abort "INPROCESS_SHARED_START_RETRIES must be numeric and >= 0"
  fi
  if ! [[ "$SESSION_LOCK_WAIT_SEC" =~ ^[0-9]+$ ]] || [[ "$SESSION_LOCK_WAIT_SEC" -lt 1 ]]; then
    abort "SESSION_LOCK_WAIT_SEC must be numeric and >= 1"
  fi

  derive_role_team_shape

  TEAM_ROOT="$REPO/.codex-teams/$TMUX_SESSION"
  TEAM_CONFIG="$TEAM_ROOT/config.json"
  TEAM_FILE="$TEAM_ROOT/team.json"
  DB="$TEAM_ROOT/bus.sqlite"
  PROMPT_DIR="$TEAM_ROOT/prompts"
  TASKS_DIR="$TEAM_ROOT/tasks"
  LOG_DIR="$TEAM_ROOT/logs"
  WORKTREES_ROOT="$(abs_path_from "$REPO" "$WORKTREES_DIR")"
  LEAD_WORKTREE="$REPO"

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

is_system_actor() {
  local ident="${1:-}"
  case "$ident" in
    system|monitor|orchestrator)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_known_team_member() {
  local ident="${1:-}"
  if [[ -z "$ident" ]]; then
    return 1
  fi
  if is_system_actor "$ident"; then
    return 0
  fi
  fs_member_names | grep -Fxq "$ident"
}

validate_sendmessage_participants() {
  local sender="$1"
  local recipient="$2"

  if ! is_known_team_member "$sender"; then
    abort "unknown sender: $sender"
  fi

  if [[ -z "$recipient" || "$recipient" == "all" ]]; then
    return 0
  fi

  if ! is_known_team_member "$recipient"; then
    abort "unknown recipient: $recipient"
  fi
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
    --cwd "$REPO" \
    --backend-type "external" \
    --mode "external" \
    "${replace_arg[@]}" >/dev/null

  local worker_backend="$RESOLVED_BACKEND"

  local agent_name
  for agent_name in "${TEAM_AGENT_NAMES[@]}"; do
    local role="${TEAM_AGENT_ROLE[$agent_name]}"
    local wt_path="$WORKTREES_ROOT/$agent_name"
    local member_cwd="$wt_path"
    if [[ "$role" != "worker" ]]; then
      member_cwd="$REPO"
    fi
    local model="${TEAM_AGENT_MODEL[$agent_name]}"
    local profile="${TEAM_AGENT_PROFILE[$agent_name]}"
    local member_mode="${TEAM_AGENT_PERMISSION[$agent_name]}"
    if [[ -z "$model" ]]; then
      model="$WORKER_MODEL"
    fi
    if [[ -z "$profile" ]]; then
      profile="$WORKER_PROFILE"
    fi
    if [[ -z "$member_mode" ]]; then
      member_mode="$PERMISSION_MODE"
    fi
    local args=(
      member-add
      --repo "$REPO"
      --session "$TMUX_SESSION"
      --name "$agent_name"
      --agent-type "$role"
      --model "$model"
      --prompt ""
      --cwd "$member_cwd"
      --backend-type "$worker_backend"
      --mode "$member_mode"
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
    --body "team_created name=$team_name session=$TMUX_SESSION roles=[$TEAM_ROLE_SUMMARY] members=$total_members runtime_members=${#TEAM_AGENT_NAMES[@]} lead_mode=external mode=$RESOLVED_BACKEND layout=shared" >/dev/null
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
  local worktree_targets=("${TEAM_AGENT_NAMES[@]}")
  for name in "${worktree_targets[@]}"; do
    if [[ "${TEAM_AGENT_ROLE[$name]}" != "worker" ]]; then
      continue
    fi
    local branch="ma/$name"
    local wt_path="$WORKTREES_ROOT/$name"
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

spawn_detached_to_log() {
  local log_file="$1"
  shift

  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" </dev/null >"$log_file" 2>&1 &
  else
    require_cmd nohup
    nohup "$@" </dev/null >"$log_file" 2>&1 &
  fi
  local pid=$!
  printf '%s\n' "$pid"
}

process_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

process_survives_window() {
  local pid="$1"
  local window_sec="$2"

  if [[ "$window_sec" -le 0 ]]; then
    process_alive "$pid"
    return $?
  fi

  local ticks=$((window_sec * 4))
  local i
  for ((i=0; i<ticks; i++)); do
    if ! process_alive "$pid"; then
      return 1
    fi
    sleep 0.25
  done

  process_alive "$pid"
}

show_process_failure_hint() {
  local label="$1"
  local pid="$2"
  local log_file="$3"

  echo "$label exited during startup window (pid=$pid). log: $log_file" >&2
  if [[ -f "$log_file" ]]; then
    tail -n 60 "$log_file" >&2 || true
  fi
}

spawn_inprocess_shared_backend() {
  mkdir -p "$LOG_DIR"

  local hub_log="$LOG_DIR/inprocess-hub.log"
  local hub_lifecycle="$LOG_DIR/inprocess-hub.lifecycle.log"
  local hub_heartbeat="$LOG_DIR/inprocess-hub.heartbeat.json"
  local hub_agents=("${TEAM_AGENT_NAMES[@]}")
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
    --lead-cwd "$REPO"
    --lead-profile "$LEAD_PROFILE"
    --lead-model "$LEAD_MODEL"
    --reviewer-name "$REVIEWER_AGENT_NAME"
    --reviewer-profile "${TEAM_AGENT_PROFILE[$REVIEWER_AGENT_NAME]}"
    --reviewer-model "${TEAM_AGENT_MODEL[$REVIEWER_AGENT_NAME]}"
    --reviewer-permission-mode "${TEAM_AGENT_PERMISSION[$REVIEWER_AGENT_NAME]}"
    --codex-bin "$CODEX_BIN"
    --poll-ms "$INPROCESS_POLL_MS"
    --idle-ms "$INPROCESS_IDLE_MS"
    --permission-mode "$PERMISSION_MODE"
    --heartbeat-file "$hub_heartbeat"
    --lifecycle-log "$hub_lifecycle"
  )
  if [[ "$PLAN_MODE_REQUIRED" == "true" ]]; then
    args+=(--plan-mode-required)
  fi

  local max_attempts=$((INPROCESS_SHARED_START_RETRIES + 1))
  local attempt
  local pid=""
  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    printf '%s startup-attempt=%s/%s session=%s backend=in-process-shared\n' \
      "$(now_utc_iso)" "$attempt" "$max_attempts" "$TMUX_SESSION" >> "$hub_lifecycle" 2>/dev/null || true

    pid="$(spawn_detached_to_log "$hub_log" "${args[@]}")"
    fs_cmd runtime-set --repo "$REPO" --session "$TMUX_SESSION" --agent "$INPROCESS_HUB_AGENT" \
      --backend in-process-shared --status running --pid "$pid" --window in-process-shared >/dev/null

    if process_survives_window "$pid" "$INPROCESS_SHARED_STABILIZE_SEC"; then
      printf '%s startup-stable pid=%s stabilize_sec=%s attempt=%s\n' \
        "$(now_utc_iso)" "$pid" "$INPROCESS_SHARED_STABILIZE_SEC" "$attempt" >> "$hub_lifecycle" 2>/dev/null || true
      python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind status \
        --body "spawned in-process shared hub pid=$pid members=$hub_count roles=[$TEAM_ROLE_SUMMARY] log=$hub_log stabilize_sec=$INPROCESS_SHARED_STABILIZE_SEC startup_attempt=$attempt" >/dev/null
      return 0
    fi

    printf '%s startup-failed pid=%s stabilize_sec=%s attempt=%s\n' \
      "$(now_utc_iso)" "$pid" "$INPROCESS_SHARED_STABILIZE_SEC" "$attempt" >> "$hub_lifecycle" 2>/dev/null || true
    python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind blocker \
      --body "in-process shared hub exited during startup window pid=$pid attempt=$attempt/$max_attempts stabilize_sec=$INPROCESS_SHARED_STABILIZE_SEC log=$hub_log lifecycle=$hub_lifecycle" >/dev/null || true
    show_process_failure_hint "in-process shared hub" "$pid" "$hub_log"
    fs_cmd runtime-mark --repo "$REPO" --session "$TMUX_SESSION" --agent "$INPROCESS_HUB_AGENT" --status terminated >/dev/null || true
    if process_alive "$pid"; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 0.2
      if process_alive "$pid"; then
        kill -KILL "$pid" >/dev/null 2>&1 || true
      fi
    fi
    sleep 0.5
  done

  abort "in-process shared hub failed startup stability check (${INPROCESS_SHARED_STABILIZE_SEC}s, attempts=$max_attempts). check: $hub_log $hub_lifecycle"
}

role_primary_objective() {
  local role="$1"
  case "$role" in
    worker)
      printf '%s\n' "Implement scoped code changes with minimal blast radius and provide concrete validation output."
      ;;
    reviewer)
      printf '%s\n' "Perform independent review only (no code changes) and report concrete findings with severity and evidence."
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
7. Maintain continuous peer collaboration: when your output depends on another worker, send \`question\` and keep Q/A looping until dependency is closed.
8. If anything is unknown mid-task, ask lead immediately with \`question\` (summary: research-request); do not guess critical requirements.
9. If lead assigns merge/release ownership, execute it using configured git binary: \`"$GIT_BIN"\`.
10. You decide completion for your assigned scope. When you judge it done, explicitly send \`status\` with summary \`done\` to lead and include changed files + validation evidence.
11. Treat other workers as first-class collaborators: request peer review with \`question\`, respond with \`answer\`, and send \`message\` summary \`peer-sync\` when interface/contracts changed.
EOF
)"
  elif [[ "$role" == "reviewer" ]]; then
    role_specific_contract="$(cat <<EOF
7. Reviewer is review-only: do not edit files, do not run write operations, do not commit.
8. Review must include severity-ranked findings with exact file paths/lines and reproduction/verification evidence.
9. Send final review to lead using \`status\` summary \`review-done\` and include explicit \`result=pass|issues\`.
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
2. Lead($TEAM_LEAD_NAME) owns research/planning/review orchestration. Escalate blockers/questions to lead quickly with concrete options.
3. Realtime collaboration is mandatory and continuous: when interfaces/requirements are unclear, ask $peer and lead with \`question\`, reply with \`answer\`, and keep iterative loops until closed.
4. Send progress and completion updates:
   codex-teams sendmessage --session "$TMUX_SESSION" --room "$ROOM" --type status --from "$agent" --to "$TEAM_LEAD_NAME" --summary "<progress|done|blocker>" --content "<update>"
5. Include evidence in done: changed files + validation command outputs + residual risk.
6. Finalization handoff: once lead approves completion, an assigned worker handles git push/merge flow.
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
3. Operate fixed runtime topology: $REVIEWER_AGENT_NAME + worker-1 + worker-2 + worker-3 (workers are fixed at 3).
4. Delegate code implementation tasks only to worker-* agents.
5. Active feedback loop is mandatory: for every worker status/blocker/question, send explicit feedback with next action, priority, and owner.
6. Mailbox reads are mention-driven: react when teammate mentions/updates arrive instead of blind polling loops.
7. Worker completion is worker-declared: treat worker \`status\` summary \`done\` as completion signal for that worker scope.
8. After all worker scopes are done, run independent lead review and request $REVIEWER_AGENT_NAME independent review.
9. Compare lead review vs reviewer review. If issues exist, synthesize a remediation plan and re-delegate fixes to worker-*.
10. Lead must remain orchestration/debug owner; do not implement feature code directly.
11. Assign one worker for final git push/merge workflow after all review issues are closed.
12. If any worker asks \`question\` with unknowns, run focused research (repo + web/docs as needed) and send refined guidance back as follow-up \`task\` or \`answer\`.
13. For each unanswered worker question/blocker, assign owner + deadline and keep follow-up until closed.
14. Keep worker mesh active: require each worker to share peer-sync updates for cross-cutting changes and ensure at least one peer review touchpoint per worker scope.
EOF
}

prepare_initial_boot_prompts() {
  BOOT_PROMPT_BY_AGENT=()
  if [[ -z "$TASK" ]]; then
    return 0
  fi

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
  workflow_summary="workflow-fixed lead-research+plan->delegate(workers)->peer-qa(continuous)+peer-sync(auto)->on-demand-research-by-lead->worker-complete->parallel-review(lead+reviewer)->review-compare->issue-redelegate(if-needed)->assigned-worker-push/merge; lead=orchestration/debug-only(external-session); reviewer=review-only(no-code-edit); unknowns=worker-question->lead-research->worker-answer/task; role-shape=[$TEAM_ROLE_SUMMARY]; policy=fixed-worker-pool-3+$REVIEWER_AGENT_NAME"
  python3 "$BUS" --db "$DB" send --room "$ROOM" --from orchestrator --to all --kind status --body "$workflow_summary" >/dev/null
  fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type status --from orchestrator --recipient all --summary "workflow-fixed" --content "$workflow_summary" >/dev/null || true
}

delegate_initial_task_to_role_agents() {
  local task_text="$1"
  local i=0
  local total="${#TEAM_AGENT_NAMES[@]}"
  local agent
  for agent in "${TEAM_AGENT_NAMES[@]}"; do
    i=$((i + 1))
    local role="${TEAM_AGENT_ROLE[$agent]}"
    if [[ "$role" == "reviewer" ]]; then
      local reviewer_hold
      reviewer_hold="reviewer standby: wait until workers complete; then perform independent review-only pass and report findings to $TEAM_LEAD_NAME."
      fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type status --from "$TEAM_LEAD_NAME" --recipient "$agent" --content "$reviewer_hold" --summary "reviewer-standby" >/dev/null
      python3 "$BUS" --db "$DB" send --room "$ROOM" --from "$TEAM_LEAD_NAME" --to "$agent" --kind status --body "$reviewer_hold" >/dev/null
      continue
    fi
    local delegated
    delegated="$(build_role_task_prompt "$agent" "$role" "$i" "$total" "$task_text")"
    fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type task --from "$TEAM_LEAD_NAME" --recipient "$agent" --content "$delegated" --summary "delegated-initial-task-$agent" >/dev/null
    python3 "$BUS" --db "$DB" send --room "$ROOM" --from "$TEAM_LEAD_NAME" --to "$agent" --kind task --body "$delegated" >/dev/null
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
  local total_members=$(( ${#TEAM_AGENT_NAMES[@]} + 1 ))
  local runtime_members="${#TEAM_AGENT_NAMES[@]}"
  echo "- role members: $total_members ($TEAM_ROLE_SUMMARY)"
  echo "- runtime members: $runtime_members (reviewer + workers)"
  echo "- lead runtime: external (current codex session)"
  echo "- lead cwd: $LEAD_WORKTREE"
  echo "- reviewer: $REVIEWER_AGENT_NAME (read-only review)"
  echo "- worker pool: $WORKER_COUNT"
  echo "- auto delegate: $AUTO_DELEGATE"
  echo "- room: $ROOM"
  echo "- bus db: $DB"
  echo "- git bin: $GIT_BIN"
  echo "- team config: $TEAM_CONFIG"
  echo "- state: $TEAM_ROOT/state.json"
  echo "- viewer bridge: $REPO/$VIEWER_BRIDGE_FILE"
  if [[ -n "$LEAD_MODEL" || -n "$WORKER_MODEL" || -n "$REVIEWER_MODEL" ]]; then
    echo "- models: lead=${LEAD_MODEL:-<default>} worker=${WORKER_MODEL:-<default>} reviewer=${REVIEWER_MODEL:-<default>}"
  fi
  echo "- logs: $LOG_DIR/inprocess-hub.log"
  echo "- in-process poll(ms): $INPROCESS_POLL_MS"
  echo "- in-process idle(ms): $INPROCESS_IDLE_MS"
  echo "- shared startup stabilize(sec): $INPROCESS_SHARED_STABILIZE_SEC"
  echo "- shared startup retries: $INPROCESS_SHARED_START_RETRIES"
  echo "- command lock wait(sec): $SESSION_LOCK_WAIT_SEC"
  echo "- status: TEAM_DB='$DB' '$STATUS' --room '$ROOM'"
  echo "- mailbox: TEAM_DB='$DB' '$MAILBOX' --repo '$REPO' --session '$TMUX_SESSION' inbox <agent> --unread"
  echo "- control: TEAM_DB='$DB' '$CONTROL' --repo '$REPO' --session '$TMUX_SESSION' request --type plan_approval <from> <to> <body>"
}

count_alive_runtime_processes() {
  python3 - "$TEAM_ROOT/runtime.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
alive = 0
try:
    with open(path, "r", encoding="utf-8") as f:
        runtime = json.load(f)
except Exception:
    print(0)
    raise SystemExit(0)

agents = runtime.get("agents", {})
if not isinstance(agents, dict):
    print(0)
    raise SystemExit(0)

for record in agents.values():
    if not isinstance(record, dict):
        continue
    if str(record.get("status", "")) != "running":
        continue
    backend = str(record.get("backend", ""))
    if backend != "in-process-shared":
        continue
    pid = int(record.get("pid", 0) or 0)
    if pid <= 0:
        continue
    try:
        os.kill(pid, 0)
    except OSError:
        continue
    alive += 1

print(alive)
PY
}

guard_existing_inprocess_runtime() {
  if [[ "$RESOLVED_BACKEND" != "in-process-shared" ]]; then
    return 0
  fi

  local alive_count
  alive_count="$(count_alive_runtime_processes)"
  if [[ "$alive_count" =~ ^[0-9]+$ ]] && [[ "$alive_count" -gt 0 ]]; then
    abort "active in-process-shared runtime already exists for session '$TMUX_SESSION' (alive=$alive_count). use status/teamdelete --force first."
  fi
}

run_swarm() {
  require_cmd "$GIT_BIN"
  require_cmd python3
  CODEX_BIN="$(require_subprocess_executable "$CODEX_BIN" "codex binary")"
  require_repo_ready_for_run
  acquire_session_lock

  if [[ "$COMMAND" == "run" && -z "$TASK" ]]; then
    abort "--task is required for run"
  fi

  guard_existing_inprocess_runtime
  init_bus_and_dirs
  ensure_worktrees
  create_or_refresh_team_context true

  prepare_initial_boot_prompts
  spawn_inprocess_shared_backend

  write_viewer_bridge "$RESOLVED_BACKEND" "shared"

  local total_members=$(( ${#TEAM_AGENT_NAMES[@]} + 1 ))
  local runtime_members="${#TEAM_AGENT_NAMES[@]}"
  python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind system \
    --body "session=$TMUX_SESSION started via codex-teams backend=$RESOLVED_BACKEND members=$total_members runtime_members=$runtime_members lead_mode=external role_shape=[$TEAM_ROLE_SUMMARY] layout=shared permission_mode=$PERMISSION_MODE" >/dev/null
  announce_collaboration_workflow

  inject_initial_task
  print_start_summary
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

  if [[ -f "$LOG_DIR/inprocess-hub.heartbeat.json" || -f "$LOG_DIR/inprocess-hub.lifecycle.log" ]]; then
    echo ""
    echo "[inprocess-shared diagnostics]"
    if [[ -f "$LOG_DIR/inprocess-hub.heartbeat.json" ]]; then
      echo "heartbeat-file=$LOG_DIR/inprocess-hub.heartbeat.json"
      cat "$LOG_DIR/inprocess-hub.heartbeat.json" 2>/dev/null || true
    fi
    if [[ -f "$LOG_DIR/inprocess-hub.lifecycle.log" ]]; then
      echo "lifecycle-log=$LOG_DIR/inprocess-hub.lifecycle.log"
      tail -n 10 "$LOG_DIR/inprocess-hub.lifecycle.log" 2>/dev/null || true
    fi
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

  if [[ "$backend" == "in-process-shared" ]]; then
    if [[ "$target" == "$INPROCESS_HUB_AGENT" ]]; then
      fs_cmd runtime-kill --repo "$REPO" --session "$TMUX_SESSION" --agent "$target" --signal term >/dev/null || true
    else
      fs_cmd dispatch --repo "$REPO" --session "$TMUX_SESSION" --type shutdown_request --from "$TEAM_LEAD_NAME" --recipient "$target" \
        --summary "shutdown-request" --content "shutdown approved; terminate teammate loop" >/dev/null || true
    fi
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
    if not isinstance(record, dict):
        continue
    if str(record.get("status", "")) != "running":
        continue
    pid = int(record.get("pid", 0) or 0)
    print(f"{name}|{pid}")
PY
)"

  local line
  local agent
  local pid
  declare -A runtime_pids=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    agent="${line%%|*}"
    pid="${line##*|}"
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
      runtime_pids["$pid"]=1
    fi
    fs_cmd runtime-kill --repo "$REPO" --session "$TMUX_SESSION" --agent "$agent" --signal term >/dev/null 2>&1 || true
  done <<< "$running_agents"

  if [[ "${#runtime_pids[@]}" -gt 0 ]]; then
    local deadline=$((SECONDS + 6))
    local any_alive
    while (( SECONDS <= deadline )); do
      any_alive=0
      for pid in "${!runtime_pids[@]}"; do
        if kill -0 "$pid" >/dev/null 2>&1; then
          any_alive=1
          break
        fi
      done
      if [[ "$any_alive" -eq 0 ]]; then
        break
      fi
      sleep 0.2
    done

    for pid in "${!runtime_pids[@]}"; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        kill -KILL "$pid" >/dev/null 2>&1 || true
      fi
    done
  fi

  # Backward-compatible fallback: older sessions may not have tracked hub runtime.
  if command -v pgrep >/dev/null 2>&1; then
    local hub_pid
    while IFS= read -r hub_pid; do
      [[ -z "$hub_pid" ]] && continue
      kill "$hub_pid" >/dev/null 2>&1 || true
    done < <(pgrep -f "team_inprocess_hub.py.*--repo $REPO.*--session $TMUX_SESSION" || true)
  fi
}

cmd_teamcreate() {
  load_config_or_defaults
  acquire_session_lock
  init_bus_and_dirs
  create_or_refresh_team_context "$TEAMCREATE_REPLACE"
  write_viewer_bridge "$RESOLVED_BACKEND" "shared"
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
# Topology is fixed by codex-teams runtime: lead(external) x1 + reviewer x1 + worker x3.

# Number of workers (fixed policy).
COUNT=3

# Worker naming prefix: worker-1, worker-2, worker-3
PREFIX="worker"

# Fixed reviewer agent name.
REVIEWER_NAME="reviewer-1"

# Where worker worktrees are created (relative to repo root or absolute path).
WORKTREES_DIR=".worktrees"

# Base commit/ref for new worker branches.
BASE_REF="HEAD"

# true: capture tracked uncommitted changes into a snapshot base for workers.
USE_BASE_WIP="false"

# true: allow dirty tree without snapshot (workers start from BASE_REF only).
ALLOW_DIRTY="true"

# Session options.
TMUX_SESSION="codex-fleet"
KILL_EXISTING_SESSION="false"

# Codex executable and profiles.
CODEX_BIN="codex"
DIRECTOR_PROFILE="xhigh"
WORKER_PROFILE="high"
REVIEWER_PROFILE="xhigh"

# Role model defaults.
LEAD_MODEL="gpt-5.3-codex"
WORKER_MODEL="gpt-5.3-codex"
REVIEWER_MODEL="gpt-5.3-codex-spark"

# Merge mode when integrating workers: merge or cherry-pick
MERGE_STRATEGY="merge"

# Backend default (resource-lean shared supervisor).
TEAMMATE_MODE="in-process-shared"
PERMISSION_MODE="default"
PLAN_MODE_REQUIRED="false"
AUTO_DELEGATE="true"
INPROCESS_POLL_MS="250"
INPROCESS_IDLE_MS="12000"
INPROCESS_SHARED_STABILIZE_SEC="12"
INPROCESS_SHARED_START_RETRIES="1"
SESSION_LOCK_WAIT_SEC="20"

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

cmd_deps() {
  require_windows_wsl_runtime_base

  local install_mode="$DEPS_INSTALL"
  if [[ "$install_mode" == "true" ]]; then
    AUTO_DEP_PM="$(detect_package_manager || true)"
    if [[ -z "$AUTO_DEP_PM" ]]; then
      echo "no supported package manager detected; install mode cannot run automatically." >&2
    else
      echo "dependency auto-install mode enabled (package manager: $AUTO_DEP_PM)"
    fi
  fi

  local rc=0
  local dep_cmd dep_required
  local deps=(
    "git|required"
    "python3|required"
    "wslpath|required"
    "codex|required"
    "sqlite3|optional"
  )

  for spec in "${deps[@]}"; do
    dep_cmd="${spec%%|*}"
    dep_required="${spec##*|}"
    if ! dependency_status_line "$dep_cmd" "$dep_required" "$install_mode"; then
      local dep_rc=$?
      if [[ "$dep_rc" -eq 2 ]]; then
        rc=2
      elif [[ "$rc" -eq 0 ]]; then
        rc=1
      fi
    fi
  done

  if [[ "$rc" -eq 0 ]]; then
    echo "dependency check complete: all required dependencies are available."
  elif [[ "$rc" -eq 1 ]]; then
    echo "dependency check complete: required dependencies are available, optional dependencies are missing."
  else
    echo "dependency check complete: required dependencies are missing."
  fi
  return "$rc"
}

cmd_setup() {
  local git_bin="$BOOT_GIT_BIN"
  require_cmd "$git_bin"
  acquire_repo_lock

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

cmd_init() {
  local config_path="$REPO/.codex-multi-agent.config.sh"
  if [[ -f "$config_path" ]]; then
    if [[ "$DELETE_FORCE" != "true" ]]; then
      echo "Config already exists: $config_path"
      echo "Use --force to overwrite."
      exit 2
    fi
    rm -f "$config_path"
  fi

  ensure_default_project_config "$config_path"
  echo "Initialized team config at: $config_path"
}

merge_worker_branch() {
  local branch="$1"
  local ahead="$2"

  if [[ "$MERGE_STRATEGY" == "merge" ]]; then
    echo "merge branch: $branch (ahead=$ahead)"
    if ! git_repo_cmd "$REPO" merge --no-ff --no-edit "$branch"; then
      return 1
    fi
    return 0
  fi

  local commits=()
  mapfile -t commits < <(git_repo_cmd "$REPO" rev-list --reverse "HEAD..$branch")
  if [[ "${#commits[@]}" -eq 0 ]]; then
    return 0
  fi
  echo "cherry-pick branch: $branch (commits=${#commits[@]})"
  if ! git_repo_cmd "$REPO" cherry-pick "${commits[@]}"; then
    return 1
  fi
  return 0
}

cmd_merge() {
  load_config_or_defaults
  require_cmd "$GIT_BIN"
  require_repo_ready_for_run

  local current_branch
  current_branch="$(git_repo_cmd "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
    abort "merge requires a checked-out branch (detached HEAD is not supported)"
  fi

  if [[ -n "$(git_repo_cmd "$REPO" status --porcelain=v1 --untracked-files=no)" ]]; then
    abort "working tree has uncommitted changes. commit/stash before merge"
  fi

  local merged_count=0
  local skipped_count=0
  local attempted_count=0
  local agent
  for agent in "${TEAM_AGENT_NAMES[@]}"; do
    if [[ "${TEAM_AGENT_ROLE[$agent]}" != "worker" ]]; then
      continue
    fi
    local branch="ma/$agent"
    if ! git_repo_cmd "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "skip missing branch: $branch"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    local ahead
    ahead="$(git_repo_cmd "$REPO" rev-list --count "HEAD..$branch" 2>/dev/null || echo 0)"
    if ! [[ "$ahead" =~ ^[0-9]+$ ]]; then
      ahead="0"
    fi
    if [[ "$ahead" == "0" ]]; then
      echo "skip no new commits: $branch"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    attempted_count=$((attempted_count + 1))
    if ! merge_worker_branch "$branch" "$ahead"; then
      if [[ "$MERGE_STRATEGY" == "merge" ]]; then
        abort "merge failed for $branch. resolve conflicts manually, then retry."
      fi
      abort "cherry-pick failed for $branch. resolve conflicts with git cherry-pick --continue/--abort."
    fi
    merged_count=$((merged_count + 1))

    if [[ -f "$DB" ]]; then
      python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind status \
        --body "merge-applied strategy=$MERGE_STRATEGY branch=$branch ahead=$ahead" >/dev/null || true
    fi
  done

  echo "merge complete"
  echo "- repo: $REPO"
  echo "- strategy: $MERGE_STRATEGY"
  echo "- merged branches: $merged_count"
  echo "- skipped branches: $skipped_count"
  echo "- attempted branches: $attempted_count"

  if [[ -f "$DB" ]]; then
    python3 "$BUS" --db "$DB" send --room "$ROOM" --from system --to all --kind status \
      --body "merge completed strategy=$MERGE_STRATEGY merged=$merged_count skipped=$skipped_count attempted=$attempted_count" >/dev/null || true
  fi
}

cmd_teamdelete() {
  load_config_or_defaults
  acquire_session_lock

  if [[ "$DELETE_FORCE" == "true" ]]; then
    force_terminate_runtime_agents
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

  local rc=0
  if [[ "$approve_flag" == "true" ]]; then
    if ! python3 "$BUS" --db "$DB" control-respond --request-id "$request_id" --from "$sender" --approve --body "$body" >/dev/null 2>&1; then
      rc=$?
    fi
  else
    if ! python3 "$BUS" --db "$DB" control-respond --request-id "$request_id" --from "$sender" --reject --body "$body" >/dev/null 2>&1; then
      rc=$?
    fi
  fi
  return "$rc"
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
  acquire_session_lock
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

  validate_sendmessage_participants "$MESSAGE_SENDER" "$recipient"

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
      local fs_rid
      fs_rid="$(fs_control_request "$req_type" "$MESSAGE_SENDER" "$recipient" "$body" "$summary" "$rid" || true)"
      if [[ -n "$fs_rid" ]]; then
        rid="$fs_rid"
      else
        local fs_req_info
        fs_req_info="$(fs_lookup_request_fields "$rid" || true)"
        if [[ "$fs_req_info" == "||" || -z "$fs_req_info" ]]; then
          abort "control request persistence failed for request_id=$rid type=$req_type; refusing orphan request dispatch"
        fi
      fi
      if [[ -f "$DB" ]]; then
        local bus_rid
        bus_rid="$(bus_control_request "$req_type" "$MESSAGE_SENDER" "$recipient" "$body" "$summary" "$rid" || true)"
        if [[ -n "$bus_rid" ]]; then
          if [[ "$bus_rid" != "$rid" ]]; then
            abort "control request id mismatch fs=$rid db=$bus_rid type=$req_type"
          fi
        else
          echo "warn: bus control request persistence failed request_id=$rid type=$req_type (fs persisted)" >&2
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
        bus_control_respond "$MESSAGE_REQUEST_ID" "$MESSAGE_SENDER" "$MESSAGE_APPROVE" "$response_body" || true
      fi

      local req_info req_type req_sender req_target
      req_info="$(bus_lookup_request_fields "$MESSAGE_REQUEST_ID" || true)"
      if [[ "$req_info" == "||" || -z "$req_info" ]]; then
        req_info="$(fs_lookup_request_fields "$MESSAGE_REQUEST_ID" || true)"
      fi
      if [[ "$req_info" == "||" || -z "$req_info" ]]; then
        abort "control response requires existing request_id=$MESSAGE_REQUEST_ID"
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
      validate_sendmessage_participants "$MESSAGE_SENDER" "$recipient"

      local response_req_type="$req_type"
      if [[ -z "$response_req_type" ]]; then
        response_req_type="$msg_type"
        response_req_type="${response_req_type%_response}"
      fi
      if ! fs_control_respond "$MESSAGE_REQUEST_ID" "$MESSAGE_SENDER" "$MESSAGE_APPROVE" "$response_body" "$recipient" "$response_req_type"; then
        abort "control response persistence failed request_id=$MESSAGE_REQUEST_ID type=$response_req_type"
      fi

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
    deps|init|setup|run|up|status|merge|teamcreate|teamdelete|sendmessage) ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      abort "unsupported command: $COMMAND"
      ;;
  esac

  if [[ "$COMMAND" == "deps" ]]; then
    require_windows_wsl_runtime_base
  else
    require_windows_wsl_runtime
  fi

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
      --reviewer-model)
        REVIEWER_MODEL="$2"
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
      --reviewer-profile)
        REVIEWER_PROFILE_OVERRIDE="$2"
        shift 2
        ;;
      --session)
        SESSION_OVERRIDE="$2"
        shift 2
        ;;
      --dashboard)
        abort "--dashboard is not supported: runtime is in-process-shared only"
        ;;
      --dashboard-window|--dashboard-lines|--dashboard-messages)
        abort "$1 is not supported: runtime is in-process-shared only"
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
      --reviewer-name)
        REVIEWER_AGENT_NAME="$2"
        REVIEWER_NAME_OVERRIDE="$2"
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
      --install)
        if [[ "$COMMAND" != "deps" ]]; then
          abort "--install is only supported with deps command"
        fi
        DEPS_INSTALL="true"
        shift
        ;;
      --teammate-mode)
        TEAMMATE_MODE="$2"
        TEAMMATE_MODE_OVERRIDE="$2"
        shift 2
        ;;
      --tmux-layout)
        abort "--tmux-layout is not supported: runtime is in-process-shared only"
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

  if [[ "$COMMAND" == "deps" ]]; then
    return 0
  fi

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

  case "$TEAMMATE_MODE" in auto|in-process-shared) ;; *) abort "--teammate-mode must be in-process-shared (auto alias allowed)" ;; esac
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
    deps)
      cmd_deps
      ;;

    init)
      cmd_init
      ;;

    setup)
      cmd_setup
      ;;

    merge)
      cmd_merge
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
