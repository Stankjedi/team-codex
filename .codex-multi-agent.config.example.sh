#!/usr/bin/env bash
# Project config for codex multi-agent orchestration.
# Topology is fixed by codex-teams runtime: lead(external) x1 + worker x3.

# Number of workers (fixed policy: 3)
COUNT=3
PREFIX="worker"

# Where worker worktrees are created (relative to repo root or absolute path).
WORKTREES_DIR=".worktrees"

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

# Merge mode when integrating workers: merge or cherry-pick
MERGE_STRATEGY="merge"

# Backend default (resource-lean shared supervisor).
TEAMMATE_MODE="in-process-shared"
TMUX_LAYOUT="split"
PERMISSION_MODE="default"
PLAN_MODE_REQUIRED="false"
AUTO_DELEGATE="true"
# true: lead inbox에서 done status를 받은 worker tmux pane/window를 자동 종료.
AUTO_KILL_DONE_WORKER_TMUX="true"
# true: tmux pane heartbeat emitter(team-pulse) 실행.
ENABLE_TMUX_PULSE="false"
# tmux mailbox bridge polling interval(ms). 값을 키우면 CPU 사용량 감소.
TMUX_MAILBOX_POLL_MS="1500"
# in-process mailbox poll interval(ms). 값을 키우면 CPU 사용량 감소.
INPROCESS_POLL_MS="1000"
# in-process idle status cadence(ms).
INPROCESS_IDLE_MS="12000"
# in-process-shared startup stabilize window(sec). 이 시간 동안 생존해야 startup 성공으로 간주.
INPROCESS_SHARED_STABILIZE_SEC="12"
# in-process-shared startup retry count (total attempts = retries + 1).
INPROCESS_SHARED_START_RETRIES="1"
# 동일 세션/레포 병렬 제어 경합 방지를 위한 lock wait timeout(sec).
SESSION_LOCK_WAIT_SEC="20"

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
