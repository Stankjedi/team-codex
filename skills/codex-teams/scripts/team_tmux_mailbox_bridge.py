#!/usr/bin/env python3
"""tmux mailbox bridge for codex-teams.

Polls filesystem inboxes and injects unread teammate messages into each running
tmux pane so teammate communication continues without manual mailbox checks.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
FS_PATH = SCRIPT_DIR / "team_fs.py"
NON_ACTIONABLE_PROMPT_TYPES = {
    "status",
    "idle_notification",
    "system",
    "plan_approval_response",
    "permission_response",
    "shutdown_response",
    "shutdown_approved",
    "shutdown_rejected",
    "mode_set_response",
}


def run_cmd(cmd: list[str]) -> tuple[int, str]:
    proc = subprocess.run(cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return proc.returncode, proc.stdout or ""


def fs_cmd(args: list[str]) -> tuple[int, str]:
    return run_cmd([sys.executable, str(FS_PATH), *args])


def has_tmux_session(session: str) -> bool:
    rc, _ = run_cmd(["tmux", "has-session", "-t", session])
    return rc == 0


def load_runtime(runtime_path: Path) -> dict:
    try:
        with runtime_path.open("r", encoding="utf-8") as f:
            decoded = json.load(f)
    except Exception:
        return {}
    return decoded if isinstance(decoded, dict) else {}


def iter_running_tmux_agents(runtime: dict) -> list[tuple[str, str]]:
    agents = runtime.get("agents", {})
    if not isinstance(agents, dict):
        return []
    rows: list[tuple[str, str]] = []
    for name, rec in agents.items():
        if not isinstance(rec, dict):
            continue
        if str(rec.get("backend", "")) != "tmux":
            continue
        if str(rec.get("status", "")) != "running":
            continue
        pane_id = str(rec.get("paneId", "")).strip()
        if not pane_id:
            continue
        rows.append((str(name), pane_id))
    return rows


def read_unread(repo: str, session: str, agent: str, limit: int) -> list[dict]:
    rc, out = fs_cmd(
        [
            "mailbox-read",
            "--repo",
            repo,
            "--session",
            session,
            "--agent",
            agent,
            "--unread",
            "--json",
            "--limit",
            str(limit),
        ]
    )
    if rc != 0 or not out.strip():
        return []
    try:
        decoded = json.loads(out)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, list):
        return []
    rows: list[dict] = []
    for item in decoded:
        if isinstance(item, dict):
            rows.append(item)
    return rows


def mark_read(repo: str, session: str, agent: str, indexes: list[int]) -> None:
    if not indexes:
        return
    cmd = [
        "mailbox-mark-read",
        "--repo",
        repo,
        "--session",
        session,
        "--agent",
        agent,
    ]
    for idx in indexes:
        cmd.extend(["--index", str(idx)])
    fs_cmd(cmd)


def trim_text(raw: str, limit: int = 1000) -> str:
    text = str(raw or "").strip()
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def parse_bool(raw: str) -> bool:
    return str(raw or "").strip().lower() in {"1", "true", "yes", "on"}


def summary_indicates_done(summary: str) -> bool:
    text = str(summary or "").strip().lower()
    if not text:
        return False
    tokens = [tok for tok in re.split(r"[^a-z0-9]+", text) if tok]
    if not tokens:
        return False
    done_tokens = {"done", "complete", "completed", "finish", "finished"}
    if "not" in tokens and any(tok in done_tokens for tok in tokens):
        return False
    return any(tok in done_tokens for tok in tokens)


def should_inject_prompt_for_message(message: dict) -> bool:
    msg_type = str(message.get("type", "message")).strip() or "message"
    if msg_type in NON_ACTIONABLE_PROMPT_TYPES:
        return False
    if msg_type.endswith("_response"):
        return False
    return True


def reply_kind_for(msg_type: str) -> str:
    if msg_type == "question":
        return "answer"
    if msg_type.endswith("_request"):
        return "status"
    if msg_type in {"blocker"}:
        return "status"
    return "status"


def build_prompt(*, agent: str, lead: str, room: str, session: str, message: dict) -> str:
    msg_type = str(message.get("type", "message")).strip() or "message"
    sender = str(message.get("from", "")).strip() or "unknown"
    summary = trim_text(str(message.get("summary", "")), limit=140)
    text = trim_text(str(message.get("text", "")), limit=1000)
    request_id = str(message.get("request_id", "")).strip()
    suggested_kind = reply_kind_for(msg_type)

    lines = [
        f"[Mailbox] to={agent} from={sender} type={msg_type} summary={summary}",
        text,
        "",
        "Immediate action:",
        f'1) Reply to sender with `codex-teams sendmessage --session "{session}" --room "{room}" --type {suggested_kind} --from "{agent}" --to "{sender}" --summary "<update>" --content "<response>"`',
    ]

    if request_id:
        lines.append(f"2) request_id={request_id} (use matching response type if this is a control request)")
    else:
        lines.append("2) Keep response concise and include next concrete step.")

    if agent == lead and msg_type in {"question", "blocker", "task", "message"}:
        lines.append("3) If this needs unknown info, run focused research now and send refined guidance back to requester.")
    elif agent != lead and msg_type in {"question", "blocker"}:
        lines.append(
            f'3) If still unresolved after one attempt, escalate to lead with `codex-teams sendmessage --session "{session}" --room "{room}" --type question --from "{agent}" --to "{lead}" --summary "research-request" --content "<what is missing>"`'
        )

    return "\n".join(lines)


def inject_prompt(pane_id: str, prompt: str) -> bool:
    rc, _ = run_cmd(["tmux", "send-keys", "-t", pane_id, "-l", "--", prompt])
    if rc != 0:
        return False
    rc, _ = run_cmd(["tmux", "send-keys", "-t", pane_id, "C-m"])
    return rc == 0


def runtime_agent_record(runtime: dict, agent: str) -> dict:
    agents = runtime.get("agents", {})
    if not isinstance(agents, dict):
        return {}
    rec = agents.get(agent)
    return rec if isinstance(rec, dict) else {}


def detect_done_worker_from_message(*, agent: str, lead: str, message: dict) -> str:
    if agent != lead:
        return ""
    if str(message.get("type", "")).strip() != "status":
        return ""
    sender = str(message.get("from", "")).strip()
    if not sender.startswith("worker-"):
        return ""
    recipient = str(message.get("recipient", "")).strip()
    if recipient and recipient != lead:
        return ""
    if not summary_indicates_done(str(message.get("summary", ""))):
        return ""
    return sender


def kill_worker_tmux_target(*, tmux_session: str, pane_id: str, window_name: str) -> bool:
    if pane_id:
        rc, _ = run_cmd(["tmux", "kill-pane", "-t", pane_id])
        if rc == 0:
            return True
    if window_name:
        rc, _ = run_cmd(["tmux", "kill-window", "-t", f"{tmux_session}:{window_name}"])
        if rc == 0:
            return True
    return False


def auto_shutdown_done_worker(
    *,
    repo: str,
    session: str,
    tmux_session: str,
    runtime: dict,
    worker: str,
) -> bool:
    rec = runtime_agent_record(runtime, worker)
    if not rec:
        return False
    if str(rec.get("backend", "")).strip() != "tmux":
        return False
    if str(rec.get("status", "")).strip() != "running":
        return False
    pane_id = str(rec.get("paneId", "")).strip()
    window_name = str(rec.get("window", "")).strip()
    if not pane_id and not window_name:
        return False

    if not kill_worker_tmux_target(tmux_session=tmux_session, pane_id=pane_id, window_name=window_name):
        return False

    fs_cmd(
        [
            "runtime-mark",
            "--repo",
            repo,
            "--session",
            session,
            "--agent",
            worker,
            "--status",
            "terminated",
        ]
    )
    rec["status"] = "terminated"
    rec["updatedAt"] = int(time.time() * 1000)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Inject unread codex-teams mailbox messages into tmux panes")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--room", default="main")
    parser.add_argument("--tmux-session", default="")
    parser.add_argument("--lead-name", default="lead")
    parser.add_argument("--auto-kill-done-workers", default="true")
    parser.add_argument("--poll-ms", type=int, default=1500)
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()

    tmux_session = args.tmux_session.strip() or args.session
    auto_kill_done_workers = parse_bool(args.auto_kill_done_workers)
    runtime_path = Path(args.repo).resolve() / ".codex-teams" / args.session / "runtime.json"

    if args.poll_ms < 100:
        args.poll_ms = 100
    if args.limit < 1:
        args.limit = 1

    while has_tmux_session(tmux_session):
        runtime = load_runtime(runtime_path)
        for agent, pane_id in iter_running_tmux_agents(runtime):
            rows = read_unread(args.repo, args.session, agent, args.limit)
            if not rows:
                continue

            marked_indexes: list[int] = []
            for row in rows:
                idx = row.get("index")
                if not isinstance(idx, int):
                    continue
                done_worker = ""
                if auto_kill_done_workers:
                    done_worker = detect_done_worker_from_message(
                        agent=agent,
                        lead=args.lead_name,
                        message=row,
                    )
                if should_inject_prompt_for_message(row):
                    prompt = build_prompt(
                        agent=agent,
                        lead=args.lead_name,
                        room=args.room,
                        session=args.session,
                        message=row,
                    )
                    if inject_prompt(pane_id, prompt):
                        marked_indexes.append(idx)
                else:
                    marked_indexes.append(idx)
                if done_worker:
                    auto_shutdown_done_worker(
                        repo=args.repo,
                        session=args.session,
                        tmux_session=tmux_session,
                        runtime=runtime,
                        worker=done_worker,
                    )
            mark_read(args.repo, args.session, agent, marked_indexes)

        time.sleep(max(0.1, args.poll_ms / 1000.0))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
