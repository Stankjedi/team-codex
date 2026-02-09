#!/usr/bin/env python3
"""Shared in-process teammate hub for codex-teams.

Runs multiple teammate mailbox loops inside one supervisor process.
Each teammate keeps independent mailbox/runtime state, while polling and
execution are coordinated from this single process.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import team_fs  # noqa: E402
import team_inprocess_agent as agent_loop  # noqa: E402


STOP = False


@dataclass
class WorkerState:
    args: argparse.Namespace
    cwd: str
    prompt_prefix: str
    pending_texts: list[str] = field(default_factory=list)
    pending_targets: dict[str, set[str]] = field(default_factory=dict)
    last_activity: int = 0
    last_idle_sent: int = 0
    stopped: bool = False


def on_signal(_signum: int, _frame: object) -> None:
    global STOP
    STOP = True


def now_ms() -> int:
    return int(time.time() * 1000)


def role_from_agent_name(name: str, lead_name: str = "lead") -> str:
    if name == lead_name:
        return "lead"
    if name.startswith("worker-"):
        return "worker"
    if name.startswith("utility-"):
        return "utility"
    return "worker"


def run_cmd(cmd: list[str], *, cwd: str) -> tuple[int, str]:
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout or ""


def fs_cmd(fs_path: Path, args: list[str]) -> tuple[int, str]:
    cmd = [sys.executable, str(fs_path), *args]
    proc = subprocess.run(cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return proc.returncode, proc.stdout or ""


def bus_cmd(bus_path: Path, db_path: Path, args: list[str]) -> None:
    cmd = [sys.executable, str(bus_path), "--db", str(db_path), *args]
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def load_unread_messages(fs_path: Path, worker: WorkerState) -> list[dict]:
    rc, stdout = fs_cmd(
        fs_path,
        [
            "mailbox-read",
            "--repo",
            worker.args.repo,
            "--session",
            worker.args.session,
            "--agent",
            worker.args.agent,
            "--unread",
            "--json",
            "--limit",
            "200",
        ],
    )
    if rc != 0 or not stdout.strip():
        return []
    try:
        decoded = json.loads(stdout)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, list):
        return []
    rows: list[dict] = []
    for row in decoded:
        if isinstance(row, dict):
            rows.append(row)
    return rows


def mark_read_indexes(fs_path: Path, worker: WorkerState, indexes: list[int]) -> None:
    if not indexes:
        return
    cmd = [
        "mailbox-mark-read",
        "--repo",
        worker.args.repo,
        "--session",
        worker.args.session,
        "--agent",
        worker.args.agent,
    ]
    for idx in indexes:
        cmd.extend(["--index", str(idx)])
    fs_cmd(fs_path, cmd)


def worker_online(bus_path: Path, db_path: Path, fs_path: Path, worker: WorkerState) -> None:
    fs_cmd(
        fs_path,
        [
            "runtime-set",
            "--repo",
            worker.args.repo,
            "--session",
            worker.args.session,
            "--agent",
            worker.args.agent,
            "--backend",
            "in-process-shared",
            "--status",
            "running",
            "--pid",
            str(os.getpid()),
            "--window",
            "in-process-shared",
        ],
    )
    bus_cmd(
        bus_path,
        db_path,
        ["register", "--room", worker.args.room, "--agent", worker.args.agent, "--role", worker.args.role],
    )
    bus_cmd(
        bus_path,
        db_path,
        [
            "send",
            "--room",
            worker.args.room,
            "--from",
            worker.args.agent,
            "--to",
            "all",
            "--kind",
            "status",
            "--body",
            f"online backend=in-process-shared pid={os.getpid()} permission_mode={worker.args.permission_mode}",
        ],
    )


def worker_offline(bus_path: Path, db_path: Path, fs_path: Path, worker: WorkerState) -> None:
    fs_cmd(
        fs_path,
        [
            "runtime-mark",
            "--repo",
            worker.args.repo,
            "--session",
            worker.args.session,
            "--agent",
            worker.args.agent,
            "--status",
            "terminated",
        ],
    )
    bus_cmd(
        bus_path,
        db_path,
        [
            "send",
            "--room",
            worker.args.room,
            "--from",
            worker.args.agent,
            "--to",
            "all",
            "--kind",
            "status",
            "--body",
            "offline backend=in-process-shared",
        ],
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="codex-teams shared in-process hub")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--room", default="main")
    parser.add_argument("--prefix", default="worker")
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--agents-csv", default="")
    parser.add_argument("--worktrees-root", required=True)
    parser.add_argument("--profile", default="pair")
    parser.add_argument("--model", default="")
    parser.add_argument("--lead-name", default="lead")
    parser.add_argument("--lead-cwd", default="")
    parser.add_argument("--lead-profile", default="")
    parser.add_argument("--lead-model", default="")
    parser.add_argument("--codex-bin", default="codex")
    parser.add_argument("--poll-ms", type=int, default=1000)
    parser.add_argument("--idle-ms", type=int, default=12000)
    parser.add_argument("--permission-mode", default="default")
    parser.add_argument("--plan-mode-required", action="store_true")
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    fs_path = SCRIPT_DIR / "team_fs.py"
    bus_path = SCRIPT_DIR / "team_bus.py"
    db_path = Path(args.repo).resolve() / ".codex-teams" / args.session / "bus.sqlite"

    paths = team_fs.resolve_paths(args.repo, args.session)
    cfg = team_fs.read_config(paths)
    lead = args.lead_name.strip() or team_fs.lead_name(cfg)
    lead_cwd = str(Path(args.lead_cwd).resolve()) if args.lead_cwd.strip() else str(Path(args.repo).resolve())
    lead_profile = args.lead_profile.strip() or args.profile
    lead_model = args.lead_model.strip() or args.model
    prompt_base = (
        "# Agent Teammate Communication\n"
        "You are running as an agent in a team. Use codex-teams sendmessage types "
        "`message` and `broadcast` for team communication.\n\n"
        "# Team Coordination\n"
        f"You are a teammate in team `{args.session}`.\n"
        f"Team config: {paths.config}\n"
        f"Task list: {paths.tasks}\n"
        f"Team leader: {lead}\n"
    )

    worktrees_root = Path(args.worktrees_root).resolve()
    workers: list[WorkerState] = []
    worker_names: list[str] = []
    if args.agents_csv.strip():
        worker_names = [part.strip() for part in args.agents_csv.split(",") if part.strip()]
    else:
        for i in range(1, args.count + 1):
            worker_names.append(f"{args.prefix}-{i}")

    for name in worker_names:
        if name == lead:
            cwd = lead_cwd
            profile = lead_profile
            model = lead_model
        else:
            cwd = str((worktrees_root / name).resolve())
            profile = args.profile
            model = args.model
        if not Path(cwd).is_dir():
            continue
        wargs = argparse.Namespace(
            repo=args.repo,
            session=args.session,
            room=args.room,
            agent=name,
            role=role_from_agent_name(name, lead_name=lead),
            cwd=cwd,
            profile=profile,
            model=model,
            codex_bin=args.codex_bin,
            poll_ms=args.poll_ms,
            idle_ms=args.idle_ms,
            permission_mode=args.permission_mode,
            plan_mode_required=bool(args.plan_mode_required),
        )
        workers.append(
            WorkerState(
                args=wargs,
                cwd=cwd,
                prompt_prefix=f"{prompt_base}\n**Your Identity:**\n- Name: {name}\n",
                last_activity=now_ms(),
            )
        )

    if not workers:
        return 0

    for worker in workers:
        worker_online(bus_path, db_path, fs_path, worker)

    while not STOP and any(not w.stopped for w in workers):
        for worker in workers:
            if STOP or worker.stopped:
                continue

            unread = load_unread_messages(fs_path, worker)
            if unread:
                indexes: list[int] = []
                messages: list[dict] = []
                for item in unread:
                    idx = item.get("index")
                    if isinstance(idx, int) and idx >= 0:
                        indexes.append(idx)
                    messages.append(item)
                mark_read_indexes(fs_path, worker, indexes)

                should_shutdown, work_messages = agent_loop.handle_control_messages(
                    args=worker.args,
                    fs_path=fs_path,
                    bus_path=bus_path,
                    db_path=db_path,
                    messages=messages,
                    cfg=cfg,
                )
                if should_shutdown:
                    worker.stopped = True
                    worker_offline(bus_path, db_path, fs_path, worker)
                    continue

                for msg in work_messages:
                    text = str(msg.get("text", "")).strip()
                    summary = str(msg.get("summary", "")).strip()
                    sender = str(msg.get("from", ""))
                    if text:
                        worker.pending_texts.append(f"from={sender} summary={summary} text={text}".strip())
                agent_loop.merge_collaboration_targets(
                    worker.pending_targets,
                    agent_loop.collect_collaboration_targets(work_messages, self_agent=worker.args.agent),
                )
                if work_messages:
                    worker.last_activity = now_ms()

            if worker.pending_texts:
                prompt = "\n".join(worker.pending_texts)
                worker.pending_texts = []
                prompt = f"{worker.prompt_prefix}\n\n{prompt}"

                cmd = agent_loop.codex_exec_base(worker.args.codex_bin, worker.args.permission_mode)
                if worker.args.model:
                    cmd.extend(["-m", worker.args.model])
                if worker.args.profile:
                    cmd.extend(["-p", worker.args.profile])
                cmd.extend(["-C", worker.cwd, prompt])

                exit_code, run_out = run_cmd(cmd, cwd=worker.cwd)
                summary = agent_loop.summarize_output(run_out, limit=220) or "empty output"
                kind = "status" if exit_code == 0 else "blocker"
                body = (
                    f"processed prompt exit={exit_code} summary={summary}"
                    if exit_code == 0
                    else f"codex exec failed exit={exit_code} summary={summary}"
                )
                if worker.args.agent != lead:
                    bus_cmd(
                        bus_path,
                        db_path,
                        [
                            "send",
                            "--room",
                            worker.args.room,
                            "--from",
                            worker.args.agent,
                            "--to",
                            lead,
                            "--kind",
                            kind,
                            "--body",
                            body,
                        ],
                    )
                    agent_loop.dispatch_message(
                        fs_path=fs_path,
                        args=worker.args,
                        msg_type="message",
                        sender=worker.args.agent,
                        recipient=lead,
                        content=body,
                        summary="work-update" if exit_code == 0 else "work-blocker",
                    )

                agent_loop.emit_collaboration_updates(
                    fs_path=fs_path,
                    bus_path=bus_path,
                    db_path=db_path,
                    args=worker.args,
                    lead=lead,
                    sender=worker.args.agent,
                    targets=worker.pending_targets,
                    result_body=body,
                    exit_code=exit_code,
                )
                worker.pending_targets = {}
                worker.last_activity = now_ms()

            current = now_ms()
            if (
                not worker.stopped
                and current - worker.last_activity >= worker.args.idle_ms
                and current - worker.last_idle_sent >= worker.args.idle_ms
            ):
                fs_cmd(
                    fs_path,
                    [
                        "send-idle",
                        "--repo",
                        worker.args.repo,
                        "--session",
                        worker.args.session,
                        "--agent",
                        worker.args.agent,
                    ],
                )
                bus_cmd(
                    bus_path,
                    db_path,
                    [
                        "send",
                        "--room",
                        worker.args.room,
                        "--from",
                        worker.args.agent,
                        "--to",
                        lead,
                        "--kind",
                        "status",
                        "--body",
                        "idle notification sent",
                    ],
                )
                worker.last_idle_sent = current

        time.sleep(max(0.1, args.poll_ms / 1000.0))

    for worker in workers:
        if not worker.stopped:
            worker_offline(bus_path, db_path, fs_path, worker)
            worker.stopped = True

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
