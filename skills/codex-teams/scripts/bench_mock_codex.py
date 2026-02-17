#!/usr/bin/env python3
"""Mock codex binary for codex-teams shared runtime benchmarks."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_FS = SCRIPT_DIR / "team_fs.py"
MAILBOX_HEADER_RE = re.compile(r"^\[Mailbox\]\s+to=(\S+)\s+from=(\S+)\s+type=(\S+)\s+summary=(.*)$")


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def run_fs_dispatch(*, repo: str, session: str, sender: str, recipient: str, content: str, summary: str) -> None:
    fs_path = os.environ.get("CODEX_BENCH_FS", str(DEFAULT_FS))
    cmd = [
        "python3",
        fs_path,
        "dispatch",
        "--repo",
        repo,
        "--session",
        session,
        "--type",
        "message",
        "--from",
        sender,
        "--recipient",
        recipient,
        "--content",
        content,
        "--summary",
        summary,
    ]
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def batch_mode() -> int:
    sleep_ms = max(0, env_int("CODEX_BENCH_EXEC_SLEEP_MS", 80))
    if sleep_ms > 0:
        time.sleep(sleep_ms / 1000.0)
    print("mock-exec-ok")
    return 0


def interactive_mode() -> int:
    enabled = env_bool("CODEX_BENCH_ENABLE_RESPONDER", True)
    repo = os.environ.get("CODEX_BENCH_REPO", "")
    session = os.environ.get("CODEX_BENCH_SESSION", "")
    lead = os.environ.get("CODEX_BENCH_LEAD", "lead").strip() or "lead"
    agent = os.environ.get("CODEX_TEAM_AGENT", "").strip() or "worker-unknown"
    sleep_ms = max(0, env_int("CODEX_BENCH_TMUX_LOOP_SLEEP_MS", 0))

    seen: set[str] = set()

    while True:
        line = sys.stdin.readline()
        if line == "":
            return 0

        stripped = line.strip()
        if not stripped:
            if sleep_ms > 0:
                time.sleep(sleep_ms / 1000.0)
            continue

        match = MAILBOX_HEADER_RE.match(stripped)
        if match and enabled and repo and session:
            _to = match.group(1).strip()
            sender = match.group(2).strip()
            msg_type = match.group(3).strip()
            summary = match.group(4).strip()
            dedupe_key = f"{sender}|{msg_type}|{summary}"
            if dedupe_key not in seen:
                seen.add(dedupe_key)
                recipient = sender if sender and sender != "all" else lead
                body = f"mock shared processed by {agent}"
                run_fs_dispatch(
                    repo=repo,
                    session=session,
                    sender=agent,
                    recipient=recipient,
                    content=body,
                    summary="work-update",
                )

        if sleep_ms > 0:
            time.sleep(sleep_ms / 1000.0)


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "exec":
        return batch_mode()
    return interactive_mode()


if __name__ == "__main__":
    raise SystemExit(main())
