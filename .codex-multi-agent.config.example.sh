#!/usr/bin/env bash
# Project config for codex multi-agent orchestration.
# Topology is fixed by codex-teams runtime: lead x1 + worker xN + utility x1.

# Number of workers (worker-1 ... worker-N)
COUNT=2
PREFIX="worker"

# Where worker worktrees are created (relative to repo root or absolute path).
WORKTREES_DIR=".worktrees"
# 리더 전용 worktree 이름(.worktrees/<name>).
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
# true: lead inbox에서 done status를 받은 worker tmux pane/window를 자동 종료.
AUTO_KILL_DONE_WORKER_TMUX="true"

# Git selection (WSL)
# Default recommendation: keep WSL git to avoid Windows conhost.exe overhead.
# codex-teams는 C:\... 입력 경로를 자동으로 WSL 경로로 변환합니다.
GIT_BIN="git"
CODEX_TEAM_GIT_BIN="$GIT_BIN"
#
# Optional Windows Git override (may spawn conhost.exe):
# GIT_BIN="/mnt/c/Program Files/Git/cmd/git.exe"
# CODEX_TEAM_GIT_BIN="$GIT_BIN"
# export PATH="/mnt/c/Program Files/Git/cmd:$PATH"
