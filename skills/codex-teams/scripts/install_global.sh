#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SKILL_NAME="codex-teams"
BIN_DIR="${HOME}/.local/bin"
LINK_MODE="false"
NO_LAUNCHERS="false"

usage() {
  cat <<'EOF'
Install codex-teams skill globally.

Usage:
  install_global.sh [options]

Options:
  --codex-home PATH   Codex home (default: ~/.codex or $CODEX_HOME)
  --skill-name NAME   Installed skill directory name (default: codex-teams)
  --bin-dir PATH      Launcher directory (default: ~/.local/bin)
  --link              Symlink skill instead of copying files
  --no-launchers      Do not install launcher scripts into bin dir
  -h, --help          Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-home)
      CODEX_HOME="$2"
      shift 2
      ;;
    --skill-name)
      SKILL_NAME="$2"
      shift 2
      ;;
    --bin-dir)
      BIN_DIR="$2"
      shift 2
      ;;
    --link)
      LINK_MODE="true"
      shift
      ;;
    --no-launchers)
      NO_LAUNCHERS="true"
      shift
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

TARGET_DIR="$CODEX_HOME/skills/$SKILL_NAME"
mkdir -p "$CODEX_HOME/skills"

if [[ "$LINK_MODE" == "true" ]]; then
  if [[ -L "$TARGET_DIR" || -d "$TARGET_DIR" ]]; then
    python3 - <<PY
import os, shutil
path = r'''$TARGET_DIR'''
if os.path.islink(path) or os.path.isfile(path):
    os.unlink(path)
elif os.path.isdir(path):
    shutil.rmtree(path)
PY
  fi
  ln -s "$SKILL_DIR" "$TARGET_DIR"
else
  python3 - <<PY
import os, shutil
src = r'''$SKILL_DIR'''
dst = r'''$TARGET_DIR'''
if os.path.isdir(dst) or os.path.islink(dst) or os.path.isfile(dst):
    if os.path.islink(dst) or os.path.isfile(dst):
        os.unlink(dst)
    else:
        shutil.rmtree(dst)
shutil.copytree(src, dst)
PY
fi

if [[ "$NO_LAUNCHERS" == "false" ]]; then
  mkdir -p "$BIN_DIR"

  cat > "$BIN_DIR/codex-teams" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$TARGET_DIR/scripts/team_codex.sh" "\$@"
EOF
  chmod +x "$BIN_DIR/codex-teams"

  cat > "$BIN_DIR/codex-teams-dashboard" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$TARGET_DIR/scripts/team_dashboard.sh" "\$@"
EOF
  chmod +x "$BIN_DIR/codex-teams-dashboard"

  cat > "$BIN_DIR/codex-teams-mailbox" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$TARGET_DIR/scripts/team_mailbox.sh" "\$@"
EOF
  chmod +x "$BIN_DIR/codex-teams-mailbox"

  cat > "$BIN_DIR/codex-teams-control" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$TARGET_DIR/scripts/team_control.sh" "\$@"
EOF
  chmod +x "$BIN_DIR/codex-teams-control"

  cat > "$BIN_DIR/codex-teams-pulse" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$TARGET_DIR/scripts/team_pulse.sh" "\$@"
EOF
  chmod +x "$BIN_DIR/codex-teams-pulse"

  cat > "$BIN_DIR/codex-teams-fs" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "python3" "$TARGET_DIR/scripts/team_fs.py" "\$@"
EOF
  chmod +x "$BIN_DIR/codex-teams-fs"
fi

# Cleanup legacy launchers from older versions.
if [[ -f "$BIN_DIR/codex-teams-run" ]]; then
  rm -f "$BIN_DIR/codex-teams-run"
fi
if [[ -f "$BIN_DIR/codex-teams-ma" ]]; then
  rm -f "$BIN_DIR/codex-teams-ma"
fi

cat <<EOF
Installed skill:
- $TARGET_DIR

Launchers:
- $BIN_DIR/codex-teams
- $BIN_DIR/codex-teams-dashboard
- $BIN_DIR/codex-teams-mailbox
- $BIN_DIR/codex-teams-control
- $BIN_DIR/codex-teams-pulse
- $BIN_DIR/codex-teams-fs

Next:
- codex-teams teamcreate --session codex-fleet --workers 3
- codex-teams run --task "<task>" --session codex-fleet
- (optional) codex-teams run --task "<task>" --workers 3
EOF
