#!/usr/bin/env bash
# Local runtime overrides for codex-teams.
# Copy to `.codex-multi-agent.config.sh` and adjust to your environment.

# Default (Linux/macOS/WSL native git)
# GIT_BIN="git"
# CODEX_TEAM_GIT_BIN="$GIT_BIN"

# WSL + Windows Git (recommended when HTTPS auth is configured in Windows Git)
# GIT_BIN="/mnt/c/Program Files/Git/cmd/git.exe"
# CODEX_TEAM_GIT_BIN="$GIT_BIN"
# export PATH="/mnt/c/Program Files/Git/cmd:$PATH"

# Optional teammates command override
# CODEX_TEAMMATE_COMMAND="codex"
