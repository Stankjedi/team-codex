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
STOP_SIGNAL = ""


@dataclass
class WorkerState:
    args: argparse.Namespace
    cwd: str
    prompt_prefix: str
    pending_texts: list[str] = field(default_factory=list)
    pending_targets: dict[str, set[str]] = field(default_factory=dict)
    last_activity: int = 0
    last_idle_sent: int = 0
    last_mention_token: int = 0
    force_mailbox_check: bool = True
    active_proc: subprocess.Popen[str] | None = None
    active_started_ms: int = 0
    stopped: bool = False


def on_signal(_signum: int, _frame: object) -> None:
    global STOP, STOP_SIGNAL
    STOP = True
    try:
        STOP_SIGNAL = signal.Signals(_signum).name
    except Exception:
        STOP_SIGNAL = str(_signum)


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


def spawn_cmd(cmd: list[str], *, cwd: str) -> tuple[subprocess.Popen[str] | None, str]:
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except OSError as exc:
        return None, f"failed to execute {' '.join(cmd)}: {exc}"
    return proc, ""


def utc_now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def append_lifecycle(log_path: str, message: str) -> None:
    if not log_path:
        return
    try:
        path = Path(log_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as f:
            f.write(f"{utc_now_iso()} {message}\n")
            f.flush()
            os.fsync(f.fileno())
    except Exception:
        return


def write_heartbeat(heartbeat_path: str, payload: dict[str, object]) -> None:
    if not heartbeat_path:
        return
    try:
        path = Path(heartbeat_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        tmp.replace(path)
    except Exception:
        return


def fs_cmd(fs_path: Path, args: list[str]) -> tuple[int, str]:
    cmd = [sys.executable, str(fs_path), *args]
    proc = subprocess.run(cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return proc.returncode, proc.stdout or ""


def bus_cmd(bus_path: Path, db_path: Path, args: list[str]) -> None:
    cmd = [sys.executable, str(bus_path), "--db", str(db_path), *args]
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def load_unread_messages(paths: team_fs.FsPaths, worker: WorkerState, *, limit: int) -> list[dict]:
    try:
        values = team_fs.mailbox_read_indexed(
            paths,
            worker.args.agent,
            unread=True,
            limit=limit,
            mark_read_selected=True,
        )
    except Exception:
        return []

    rows: list[dict] = []
    for idx, row in values:
        if not isinstance(row, dict):
            continue
        rows.append({"index": idx, **row})
    return rows


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


def build_worker_cmd(worker: WorkerState, prompt: str) -> list[str]:
    cmd = agent_loop.codex_exec_base(worker.args.codex_bin, worker.args.permission_mode)
    if worker.args.model:
        cmd.extend(["-m", worker.args.model])
    if worker.args.profile:
        cmd.extend(["-p", worker.args.profile])
    cmd.extend(["-C", worker.cwd, prompt])
    return cmd


def publish_worker_result(
    *,
    worker: WorkerState,
    lead: str,
    fs_path: Path,
    bus_path: Path,
    db_path: Path,
    exit_code: int,
    run_out: str,
) -> None:
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


def collect_completed_output(proc: subprocess.Popen[str]) -> str:
    out = ""
    try:
        if proc.stdout is not None:
            out = proc.stdout.read()
    except Exception:
        out = ""
    return out or ""


def terminate_worker_proc(worker: WorkerState, timeout_sec: float = 5.0) -> None:
    proc = worker.active_proc
    if proc is None:
        return
    if proc.poll() is None:
        try:
            proc.terminate()
        except Exception:
            pass
        deadline = time.time() + timeout_sec
        while proc.poll() is None and time.time() < deadline:
            time.sleep(0.1)
        if proc.poll() is None:
            try:
                proc.kill()
            except Exception:
                pass
    collect_completed_output(proc)
    worker.active_proc = None
    worker.active_started_ms = 0


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
    parser.add_argument("--heartbeat-file", default="")
    parser.add_argument("--lifecycle-log", default="")
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    fs_path = SCRIPT_DIR / "team_fs.py"
    bus_path = SCRIPT_DIR / "team_bus.py"
    db_path = Path(args.repo).resolve() / ".codex-teams" / args.session / "bus.sqlite"
    append_lifecycle(
        args.lifecycle_log,
        f"hub-start pid={os.getpid()} repo={Path(args.repo).resolve()} session={args.session} room={args.room}",
    )

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
            bus_cmd(
                bus_path,
                db_path,
                [
                    "send",
                    "--room",
                    args.room,
                    "--from",
                    "system",
                    "--to",
                    "all",
                    "--kind",
                    "status",
                    "--body",
                    f"skip worker bootstrap: missing worktree agent={name} cwd={cwd}",
                ],
            )
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
                last_mention_token=team_fs.mailbox_signal_token(paths, name),
            )
        )

    if not workers:
        append_lifecycle(args.lifecycle_log, "hub-abort no-worker-worktrees")
        bus_cmd(
            bus_path,
            db_path,
            [
                "send",
                "--room",
                args.room,
                "--from",
                "system",
                "--to",
                "all",
                "--kind",
                "blocker",
                "--body",
                "in-process-shared hub aborted: no worker worktrees available",
            ],
        )
        return 2

    append_lifecycle(
        args.lifecycle_log,
        f"hub-workers-ready count={len(workers)} workers={','.join(w.args.agent for w in workers)}",
    )

    for worker in workers:
        worker_online(bus_path, db_path, fs_path, worker)

    last_heartbeat = 0
    while not STOP and any(not w.stopped for w in workers):
        for worker in workers:
            if STOP or worker.stopped:
                continue

            mention_token = team_fs.mailbox_signal_token(paths, worker.args.agent)
            should_check_mailbox = worker.force_mailbox_check or mention_token != worker.last_mention_token
            unread: list[dict] = []
            if should_check_mailbox:
                unread = load_unread_messages(paths, worker, limit=200)
                worker.force_mailbox_check = False
                worker.last_mention_token = mention_token
            if unread:
                messages: list[dict] = []
                for item in unread:
                    messages.append(item)

                should_shutdown, work_messages = agent_loop.handle_control_messages(
                    args=worker.args,
                    fs_path=fs_path,
                    bus_path=bus_path,
                    db_path=db_path,
                    messages=messages,
                    cfg=cfg,
                )
                if should_shutdown:
                    terminate_worker_proc(worker)
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

            if worker.pending_texts and worker.active_proc is None:
                prompt = "\n".join(worker.pending_texts)
                worker.pending_texts = []
                prompt = f"{worker.prompt_prefix}\n\n{prompt}"
                cmd = build_worker_cmd(worker, prompt)
                proc, err = spawn_cmd(cmd, cwd=worker.cwd)
                if proc is None:
                    publish_worker_result(
                        worker=worker,
                        lead=lead,
                        fs_path=fs_path,
                        bus_path=bus_path,
                        db_path=db_path,
                        exit_code=127,
                        run_out=err,
                    )
                else:
                    worker.active_proc = proc
                    worker.active_started_ms = now_ms()
                    worker.last_activity = worker.active_started_ms

            if worker.active_proc is not None:
                exit_code = worker.active_proc.poll()
                if exit_code is not None:
                    run_out = collect_completed_output(worker.active_proc)
                    worker.active_proc = None
                    worker.active_started_ms = 0
                    publish_worker_result(
                        worker=worker,
                        lead=lead,
                        fs_path=fs_path,
                        bus_path=bus_path,
                        db_path=db_path,
                        exit_code=exit_code,
                        run_out=run_out,
                    )

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

        current_loop_ms = now_ms()
        if current_loop_ms - last_heartbeat >= max(500, args.poll_ms):
            active_workers = sum(1 for w in workers if not w.stopped)
            write_heartbeat(
                args.heartbeat_file,
                {
                    "ts": utc_now_iso(),
                    "pid": os.getpid(),
                    "session": args.session,
                    "room": args.room,
                    "active_workers": active_workers,
                    "total_workers": len(workers),
                    "stop": STOP,
                },
            )
            last_heartbeat = current_loop_ms

        time.sleep(max(0.1, args.poll_ms / 1000.0))

    for worker in workers:
        terminate_worker_proc(worker)
    for worker in workers:
        if not worker.stopped:
            worker_offline(bus_path, db_path, fs_path, worker)
            worker.stopped = True

    stop_reason = "all-workers-stopped"
    if STOP:
        stop_reason = f"signal:{STOP_SIGNAL or 'unknown'}"
    append_lifecycle(
        args.lifecycle_log,
        f"hub-stop reason={stop_reason} active_workers={sum(1 for w in workers if not w.stopped)}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
