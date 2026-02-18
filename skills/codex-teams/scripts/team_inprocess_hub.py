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
import shlex
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
MAX_CAPTURE_BYTES = 200_000
MAX_DRAIN_BYTES_PER_TICK = 64_000
MAX_DRAIN_CHUNKS_PER_TICK = 16
WORKER_MAILBOX_BATCH = 200
LEAD_MAILBOX_SCAN_BATCH = 500
MAX_PROMPT_MESSAGES_PER_RUN = 8
MAX_PROMPT_CHARS_PER_RUN = 12_000
ACTIVE_LOOP_SLEEP_SEC = 0.02
FAST_LOOP_SLEEP_SEC = 0.05
FS_CMD_RETRIES = 2
BUS_CMD_RETRIES = 3
CMD_RETRY_BASE_SEC = 0.08
HUB_LIFECYCLE_LOG = ""


@dataclass
class WorkerState:
    args: argparse.Namespace
    cwd: str
    prompt_prefix: str
    pending_texts: list[str] = field(default_factory=list)
    pending_indexes: list[int] = field(default_factory=list)
    pending_index_set: set[int] = field(default_factory=set)
    pending_targets: dict[str, set[str]] = field(default_factory=dict)
    mailbox_scan_index: int = 0
    last_activity: int = 0
    last_idle_sent: int = 0
    last_mention_token: int = 0
    force_mailbox_check: bool = False
    active_proc: subprocess.Popen[str] | None = None
    active_started_ms: int = 0
    active_output_chunks: list[str] = field(default_factory=list)
    active_output_bytes: int = 0
    active_output_truncated: bool = False
    active_indexes: list[int] = field(default_factory=list)
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


def role_from_agent_name(name: str, lead_name: str = "lead", reviewer_name: str = "reviewer-1") -> str:
    if name == lead_name:
        return "lead"
    if name == reviewer_name:
        return "reviewer"
    if name.startswith("reviewer-"):
        return "reviewer"
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
    try:
        if proc.stdout is not None:
            os.set_blocking(proc.stdout.fileno(), False)
    except OSError:
        pass
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
    return _run_py_cmd(
        cmd,
        retries=FS_CMD_RETRIES,
        retry_delay=CMD_RETRY_BASE_SEC,
        source="fs",
    )


def bus_cmd(bus_path: Path, db_path: Path, args: list[str]) -> tuple[int, str]:
    cmd = [sys.executable, str(bus_path), "--db", str(db_path), *args]
    return _run_py_cmd(
        cmd,
        retries=BUS_CMD_RETRIES,
        retry_delay=CMD_RETRY_BASE_SEC,
        source="bus",
    )


def _format_cmd(parts: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in parts)


def _run_py_cmd(
    cmd: list[str],
    *,
    retries: int,
    retry_delay: float,
    source: str,
) -> tuple[int, str]:
    max_attempts = max(1, retries + 1)
    out = ""
    rc = 0
    for attempt in range(1, max_attempts + 1):
        proc = subprocess.run(
            cmd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        rc = int(proc.returncode)
        out = proc.stdout or ""
        if rc == 0:
            return 0, out
        if attempt < max_attempts:
            time.sleep(retry_delay * attempt)
    snippet = " ".join(out.strip().splitlines()[-3:])[:500]
    append_lifecycle(
        HUB_LIFECYCLE_LOG,
        f"{source}-cmd-failed rc={rc} attempts={max_attempts} cmd={_format_cmd(cmd)} output={snippet}",
    )
    return rc, out


def load_unread_messages(paths: team_fs.FsPaths, worker: WorkerState, *, limit: int) -> list[dict]:
    start_index = worker.mailbox_scan_index
    try:
        values = team_fs.mailbox_read_indexed(
            paths,
            worker.args.agent,
            unread=True,
            limit=limit,
            start_index=start_index,
            oldest_first=True,
            mark_read_selected=False,
        )
    except Exception:
        return []

    if not values and start_index > 0:
        # Resync when older unread rows still exist (e.g., partial ack failure/race).
        try:
            oldest_unread = team_fs.mailbox_read_indexed(
                paths,
                worker.args.agent,
                unread=True,
                limit=1,
                start_index=0,
                oldest_first=True,
                mark_read_selected=False,
            )
        except Exception:
            oldest_unread = []
        if oldest_unread:
            oldest_idx = oldest_unread[0][0]
            if isinstance(oldest_idx, int) and 0 <= oldest_idx < start_index:
                worker.mailbox_scan_index = oldest_idx
                try:
                    values = team_fs.mailbox_read_indexed(
                        paths,
                        worker.args.agent,
                        unread=True,
                        limit=limit,
                        start_index=worker.mailbox_scan_index,
                        oldest_first=True,
                        mark_read_selected=False,
                    )
                except Exception:
                    return []

    if values:
        max_seen = max(idx for idx, _ in values if isinstance(idx, int))
        if max_seen + 1 > worker.mailbox_scan_index:
            worker.mailbox_scan_index = max_seen + 1

    rows: list[dict] = []
    for idx, row in values:
        if not isinstance(row, dict):
            continue
        rows.append({"index": idx, **row})
    return rows


def load_unread_messages_no_mark(
    paths: team_fs.FsPaths,
    agent: str,
    *,
    limit: int,
    start_index: int = 0,
) -> list[dict]:
    try:
        values = team_fs.mailbox_read_indexed(
            paths,
            agent,
            unread=True,
            limit=limit,
            start_index=start_index,
            oldest_first=True,
            mark_read_selected=False,
        )
    except Exception:
        return []

    rows: list[dict] = []
    for idx, row in values:
        if not isinstance(row, dict):
            continue
        rows.append({"index": idx, **row})
    return rows


def worker_index_inflight(worker: WorkerState, idx: int) -> bool:
    if idx < 0:
        return False
    if idx in worker.pending_index_set:
        return True
    return idx in worker.active_indexes


def mark_worker_indexes_read(paths: team_fs.FsPaths, worker: WorkerState, indexes: list[int]) -> bool:
    if not indexes:
        return True
    unique = sorted({idx for idx in indexes if isinstance(idx, int) and idx >= 0})
    if not unique:
        return True
    try:
        marked = team_fs.mark_read(paths, worker.args.agent, indexes=unique, mark_all=False)
    except Exception:
        marked = 0
    ok = marked >= len(unique)
    if not ok:
        worker.force_mailbox_check = True
        worker.mailbox_scan_index = 0
    return ok


def has_unread_messages(paths: team_fs.FsPaths, agent: str) -> bool:
    rows = load_unread_messages_no_mark(paths, agent, limit=1, start_index=0)
    return bool(rows)


def pop_worker_prompt_batch(worker: WorkerState) -> tuple[list[str], list[int]]:
    lines: list[str] = []
    indexes: list[int] = []
    total_chars = 0

    while worker.pending_texts and len(lines) < MAX_PROMPT_MESSAGES_PER_RUN:
        next_line = worker.pending_texts[0]
        projected = total_chars + len(next_line) + 1
        if lines and projected > MAX_PROMPT_CHARS_PER_RUN:
            break
        lines.append(worker.pending_texts.pop(0))
        total_chars = projected
        if worker.pending_indexes:
            msg_idx = worker.pending_indexes.pop(0)
            indexes.append(msg_idx)
            if isinstance(msg_idx, int) and msg_idx >= 0:
                worker.pending_index_set.discard(msg_idx)
        if total_chars >= MAX_PROMPT_CHARS_PER_RUN:
            break

    return lines, indexes


def build_prompt_prefix(*, session: str, config_path: Path, task_path: Path, lead: str, name: str) -> str:
    return (
        "# Agent Teammate Communication\n"
        "You are running as an agent in a team. Use codex-teams sendmessage types "
        "`message` and `broadcast` for team communication.\n\n"
        "# Team Coordination\n"
        f"You are a teammate in team `{session}`.\n"
        f"Team config: {config_path}\n"
        f"Task list: {task_path}\n"
        f"Team leader: {lead}\n"
        f"\n**Your Identity:**\n- Name: {name}\n"
    )


def compute_loop_sleep(
    *,
    args: argparse.Namespace,
    workers: list[WorkerState],
    force_lead_scan: bool,
    did_work: bool,
) -> float:
    if did_work:
        return ACTIVE_LOOP_SLEEP_SEC
    if force_lead_scan:
        return ACTIVE_LOOP_SLEEP_SEC
    active_proc_present = False
    for worker in workers:
        if worker.stopped:
            continue
        if worker.active_proc is not None:
            active_proc_present = True
            continue
        if worker.pending_texts or worker.force_mailbox_check:
            return ACTIVE_LOOP_SLEEP_SEC
    if active_proc_present:
        return FAST_LOOP_SLEEP_SEC
    idle_sleep = max(FAST_LOOP_SLEEP_SEC, args.poll_ms / 1000.0)
    return min(idle_sleep, 0.25)


def all_workers_review_ready(workers: list[WorkerState], worker_done: dict[str, bool]) -> bool:
    if not worker_done:
        return False
    for worker in workers:
        if worker.args.role != "worker" or worker.stopped:
            continue
        if not worker_done.get(worker.args.agent, False):
            return False
        if worker.active_proc is not None:
            return False
        if worker.pending_texts:
            return False
        if worker.pending_indexes or worker.pending_index_set:
            return False
        if worker.force_mailbox_check:
            return False
    return True


def notify_review_ready(
    *,
    fs_path: Path,
    bus_path: Path,
    db_path: Path,
    repo: str,
    session: str,
    room: str,
    lead: str,
    reviewers: list[str],
    worker_done: dict[str, bool],
) -> None:
    done_workers = [name for name, done in worker_done.items() if done]
    done_workers.sort()
    body = (
        "all worker-* agents are runtime-complete (last run successful, queue drained). "
        f"ready for independent lead+reviewer review. workers={','.join(done_workers)} "
        "if any issue is found, synthesize remediation and re-delegate fixes to workers."
    )
    bus_cmd(
        bus_path,
        db_path,
        [
            "send",
            "--room",
            room,
            "--from",
            "system",
            "--to",
            lead,
            "--kind",
            "status",
            "--body",
            body,
        ],
    )
    fs_cmd(
        fs_path,
        [
            "dispatch",
            "--repo",
            repo,
            "--session",
            session,
            "--type",
            "status",
            "--from",
            "system",
            "--recipient",
            lead,
            "--summary",
            "review-ready",
            "--content",
            body,
        ],
    )
    for reviewer in reviewers:
        reviewer_prompt = (
            "review-only mission: workers are complete. "
            "Review worker changes independently. Do not modify files. "
            "Report findings to lead with severity/file:line evidence and conclude with result=pass|issues."
        )
        bus_cmd(
            bus_path,
            db_path,
            [
                "send",
                "--room",
                room,
                "--from",
                "system",
                "--to",
                reviewer,
                "--kind",
                "task",
                "--body",
                reviewer_prompt,
            ],
        )
        fs_cmd(
            fs_path,
            [
                "dispatch",
                "--repo",
                repo,
                "--session",
                session,
                "--type",
                "task",
                "--from",
                "system",
                "--recipient",
                reviewer,
                "--summary",
                "review-round-trigger",
                "--content",
                reviewer_prompt,
            ],
        )


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
            "0",
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
            (
                "online backend=in-process-shared pid=0 "
                f"hub_pid={os.getpid()} permission_mode={worker.args.permission_mode}"
            ),
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
    state = "complete" if exit_code == 0 else "failed"
    result_label = "worker_result"
    summary_tag = "worker-run-complete" if exit_code == 0 else "worker-run-failed"
    if worker.args.role == "reviewer":
        result_label = "reviewer_result"
        summary_tag = "reviewer-run-complete" if exit_code == 0 else "reviewer-run-failed"
    body = f"{result_label} state={state} exit={exit_code} summary={summary}"
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
            summary=summary_tag,
            meta={
                "source": "worker-result",
                "worker": worker.args.agent,
                "state": state,
                "exit_code": exit_code,
            },
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


def reset_worker_output_capture(worker: WorkerState) -> None:
    worker.active_output_chunks = []
    worker.active_output_bytes = 0
    worker.active_output_truncated = False


def drain_worker_output(worker: WorkerState, *, drain_all: bool = False) -> None:
    proc = worker.active_proc
    if proc is None or proc.stdout is None:
        return
    fd = proc.stdout.fileno()
    drained_bytes = 0
    drained_chunks = 0
    while True:
        if not drain_all:
            if drained_bytes >= MAX_DRAIN_BYTES_PER_TICK:
                break
            if drained_chunks >= MAX_DRAIN_CHUNKS_PER_TICK:
                break
        try:
            chunk = os.read(fd, 8192)
        except BlockingIOError:
            break
        except OSError:
            break
        if not chunk:
            break
        drained_bytes += len(chunk)
        drained_chunks += 1
        if worker.active_output_bytes >= MAX_CAPTURE_BYTES:
            worker.active_output_truncated = True
            continue
        remaining = MAX_CAPTURE_BYTES - worker.active_output_bytes
        take = chunk[:remaining]
        worker.active_output_bytes += len(take)
        worker.active_output_chunks.append(take.decode("utf-8", errors="replace"))
        if len(chunk) > remaining:
            worker.active_output_truncated = True


def collected_worker_output(worker: WorkerState) -> str:
    out = "".join(worker.active_output_chunks).strip()
    if worker.active_output_truncated:
        suffix = "\n[output truncated]"
        out = f"{out}{suffix}" if out else suffix.strip()
    return out


def terminate_worker_proc(worker: WorkerState, timeout_sec: float = 5.0) -> None:
    proc = worker.active_proc
    if proc is None:
        return
    if proc.poll() is None:
        try:
            proc.terminate()
        except Exception as exc:
            append_lifecycle(args.lifecycle_log, f"config-refresh-failed error={exc}")
        deadline = time.time() + timeout_sec
        while proc.poll() is None and time.time() < deadline:
            time.sleep(0.1)
        if proc.poll() is None:
            try:
                proc.kill()
            except Exception:
                pass
    drain_worker_output(worker, drain_all=True)
    worker.active_proc = None
    worker.active_started_ms = 0
    worker.active_indexes = []
    reset_worker_output_capture(worker)


def main() -> int:
    global HUB_LIFECYCLE_LOG
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
    parser.add_argument("--reviewer-name", default="reviewer-1")
    parser.add_argument("--reviewer-profile", default="")
    parser.add_argument("--reviewer-model", default="")
    parser.add_argument("--reviewer-permission-mode", default="plan")
    parser.add_argument("--codex-bin", default="codex")
    parser.add_argument("--poll-ms", type=int, default=1000)
    parser.add_argument("--idle-ms", type=int, default=12000)
    parser.add_argument("--permission-mode", default="default")
    parser.add_argument("--plan-mode-required", action="store_true")
    parser.add_argument("--heartbeat-file", default="")
    parser.add_argument("--lifecycle-log", default="")
    args = parser.parse_args()
    HUB_LIFECYCLE_LOG = args.lifecycle_log

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    fs_path = SCRIPT_DIR / "team_fs.py"
    bus_path = SCRIPT_DIR / "team_bus.py"
    paths = team_fs.resolve_paths(args.repo, args.session)
    db_path = paths.root / "bus.sqlite"
    append_lifecycle(
        args.lifecycle_log,
        f"hub-start pid={os.getpid()} repo={Path(args.repo).resolve()} session={args.session} room={args.room}",
    )

    cfg = team_fs.read_config(paths)
    lead = args.lead_name.strip() or team_fs.lead_name(cfg)
    lead_cwd = str(Path(args.lead_cwd).resolve()) if args.lead_cwd.strip() else str(Path(args.repo).resolve())
    lead_profile = args.lead_profile.strip() or args.profile
    lead_model = args.lead_model.strip() or args.model
    worktrees_root = Path(args.worktrees_root).resolve()
    workers: list[WorkerState] = []
    worker_names: list[str] = []
    if args.agents_csv.strip():
        worker_names = [part.strip() for part in args.agents_csv.split(",") if part.strip()]
    else:
        for i in range(1, args.count + 1):
            worker_names.append(f"{args.prefix}-{i}")

    for name in worker_names:
        role = role_from_agent_name(name, lead_name=lead, reviewer_name=args.reviewer_name)
        if name == lead:
            cwd = lead_cwd
            profile = lead_profile
            model = lead_model
            permission_mode = args.permission_mode
        elif role == "reviewer":
            cwd = lead_cwd
            profile = args.reviewer_profile.strip() or args.profile
            model = args.reviewer_model.strip() or args.model
            permission_mode = args.reviewer_permission_mode.strip() or "plan"
        else:
            cwd = str((worktrees_root / name).resolve())
            profile = args.profile
            model = args.model
            permission_mode = args.permission_mode
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
            role=role,
            cwd=cwd,
            profile=profile,
            model=model,
            codex_bin=args.codex_bin,
            poll_ms=args.poll_ms,
            idle_ms=args.idle_ms,
            permission_mode=permission_mode,
            plan_mode_required=bool(args.plan_mode_required),
        )
        workers.append(
            WorkerState(
                args=wargs,
                cwd=cwd,
                prompt_prefix=build_prompt_prefix(
                    session=args.session,
                    config_path=paths.config,
                    task_path=paths.tasks,
                    lead=lead,
                    name=name,
                ),
                last_activity=now_ms(),
                last_mention_token=0,
                force_mailbox_check=False,
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
    fs_cmd(
        fs_path,
        [
            "runtime-set",
            "--repo",
            args.repo,
            "--session",
            args.session,
            "--agent",
            "inprocess-hub",
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

    worker_done: dict[str, bool] = {
        worker.args.agent: False for worker in workers if worker.args.role == "worker"
    }
    reviewer_names = [worker.args.agent for worker in workers if worker.args.role == "reviewer"]
    review_ready_announced = False
    lead_last_mention_token = 0
    lead_last_scanned_index = 0
    force_lead_scan = False
    last_heartbeat = 0
    while not STOP and any(not w.stopped for w in workers):
        did_work = False
        try:
            latest_cfg = team_fs.read_config(paths)
            latest_lead = args.lead_name.strip() or team_fs.lead_name(latest_cfg)
            if latest_lead and latest_lead != lead:
                lead = latest_lead
                for worker in workers:
                    worker.prompt_prefix = build_prompt_prefix(
                        session=args.session,
                        config_path=paths.config,
                        task_path=paths.tasks,
                        lead=lead,
                        name=worker.args.agent,
                    )
            cfg = latest_cfg
        except Exception:
            pass

        for worker in workers:
            if STOP or worker.stopped:
                continue

            mention_token = team_fs.mailbox_signal_token(paths, worker.args.agent)
            should_check_mailbox = worker.force_mailbox_check or mention_token != worker.last_mention_token
            unread: list[dict] = []
            if should_check_mailbox:
                unread = load_unread_messages(paths, worker, limit=WORKER_MAILBOX_BATCH)
                worker.force_mailbox_check = False
                worker.last_mention_token = mention_token
                if len(unread) >= WORKER_MAILBOX_BATCH:
                    worker.force_mailbox_check = True
            if unread:
                messages = unread
                should_shutdown = False
                work_messages: list[dict] = []
                try:
                    should_shutdown, work_messages = agent_loop.handle_control_messages(
                        args=worker.args,
                        fs_path=fs_path,
                        bus_path=bus_path,
                        db_path=db_path,
                        messages=messages,
                        cfg=cfg,
                    )
                except Exception as exc:
                    worker.force_mailbox_check = True
                    bus_cmd(
                        bus_path,
                        db_path,
                        [
                            "send",
                            "--room",
                            worker.args.room,
                            "--from",
                            "system",
                            "--to",
                            lead,
                            "--kind",
                            "blocker",
                            "--body",
                            f"hub message handling failed agent={worker.args.agent} error={exc}",
                        ],
                    )
                    append_lifecycle(
                        args.lifecycle_log,
                        f"worker-message-handle-error agent={worker.args.agent} error={exc}",
                    )
                    continue

                actionable_indexes: set[int] = set()
                for msg in work_messages:
                    idx = msg.get("index")
                    if isinstance(idx, int) and idx >= 0:
                        actionable_indexes.add(idx)
                immediate_ack_indexes: list[int] = []
                for row in messages:
                    idx = row.get("index")
                    if not isinstance(idx, int) or idx < 0:
                        continue
                    if idx not in actionable_indexes:
                        immediate_ack_indexes.append(idx)
                mark_worker_indexes_read(paths, worker, immediate_ack_indexes)
                immediate_ack_indexes = []

                if should_shutdown:
                    mark_worker_indexes_read(paths, worker, sorted(actionable_indexes))
                    terminate_worker_proc(worker)
                    worker.stopped = True
                    worker_offline(bus_path, db_path, fs_path, worker)
                    if worker.args.role == "worker":
                        worker_done[worker.args.agent] = False
                        review_ready_announced = False
                    did_work = True
                    continue

                for msg in work_messages:
                    idx = msg.get("index")
                    msg_index = idx if isinstance(idx, int) and idx >= 0 else None
                    if msg_index is not None and worker_index_inflight(worker, msg_index):
                        # Keep unread until current in-flight handling completes.
                        continue
                    text = str(msg.get("text", "")).strip()
                    summary = str(msg.get("summary", "")).strip()
                    sender = str(msg.get("from", ""))
                    if text:
                        worker.pending_texts.append(f"from={sender} summary={summary} text={text}".strip())
                        indexed_msg = msg_index if msg_index is not None else -1
                        worker.pending_indexes.append(indexed_msg)
                        if msg_index is not None:
                            worker.pending_index_set.add(msg_index)
                    elif msg_index is not None:
                        immediate_ack_indexes.append(msg_index)
                agent_loop.merge_collaboration_targets(
                    worker.pending_targets,
                    agent_loop.collect_collaboration_targets(work_messages, self_agent=worker.args.agent),
                )
                mark_worker_indexes_read(paths, worker, immediate_ack_indexes)
                if work_messages:
                    worker.last_activity = now_ms()
                    if worker.args.role == "worker":
                        worker_done[worker.args.agent] = False
                        review_ready_announced = False
                    did_work = True

            if worker.pending_texts and worker.active_proc is None:
                prompt_lines, prompt_indexes = pop_worker_prompt_batch(worker)
                if not prompt_lines:
                    continue
                prompt = "\n".join(prompt_lines)
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
                    mark_worker_indexes_read(paths, worker, prompt_indexes)
                    if worker.args.role == "worker":
                        worker_done[worker.args.agent] = False
                        review_ready_announced = False
                else:
                    worker.active_proc = proc
                    worker.active_started_ms = now_ms()
                    worker.last_activity = worker.active_started_ms
                    worker.active_indexes = [idx for idx in prompt_indexes if isinstance(idx, int) and idx >= 0]
                    reset_worker_output_capture(worker)
                    if worker.args.role == "worker":
                        worker_done[worker.args.agent] = False
                        review_ready_announced = False
                did_work = True

            if worker.active_proc is not None:
                drain_worker_output(worker)
                exit_code = worker.active_proc.poll()
                if exit_code is not None:
                    drain_worker_output(worker, drain_all=True)
                    run_out = collected_worker_output(worker)
                    worker.active_proc = None
                    worker.active_started_ms = 0
                    reset_worker_output_capture(worker)
                    publish_worker_result(
                        worker=worker,
                        lead=lead,
                        fs_path=fs_path,
                        bus_path=bus_path,
                        db_path=db_path,
                        exit_code=exit_code,
                        run_out=run_out,
                    )
                    ack_ok = mark_worker_indexes_read(paths, worker, worker.active_indexes)
                    worker.active_indexes = []
                    if worker.args.role == "worker":
                        no_unread = not has_unread_messages(paths, worker.args.agent)
                        worker_done[worker.args.agent] = bool(
                            exit_code == 0
                            and not worker.pending_texts
                            and not worker.pending_indexes
                            and not worker.pending_index_set
                            and ack_ok
                            and no_unread
                        )
                        if not no_unread:
                            worker.force_mailbox_check = True
                        review_ready_announced = False
                    did_work = True

            current = now_ms()
            if (
                not worker.stopped
                and worker.active_proc is None
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
                did_work = True

        lead_mention_token = team_fs.mailbox_signal_token(paths, lead)
        should_scan_lead = force_lead_scan or lead_mention_token != lead_last_mention_token
        if should_scan_lead:
            lead_rows = load_unread_messages_no_mark(
                paths,
                lead,
                limit=LEAD_MAILBOX_SCAN_BATCH,
                start_index=lead_last_scanned_index,
            )
            if not lead_rows and lead_last_scanned_index > 0:
                oldest_lead = load_unread_messages_no_mark(
                    paths,
                    lead,
                    limit=1,
                    start_index=0,
                )
                if oldest_lead:
                    oldest_idx = oldest_lead[0].get("index")
                    if isinstance(oldest_idx, int) and 0 <= oldest_idx < lead_last_scanned_index:
                        lead_last_scanned_index = oldest_idx
                        lead_rows = load_unread_messages_no_mark(
                            paths,
                            lead,
                            limit=LEAD_MAILBOX_SCAN_BATCH,
                            start_index=lead_last_scanned_index,
                        )
            for row in lead_rows:
                idx = row.get("index")
                if isinstance(idx, int) and idx >= lead_last_scanned_index:
                    lead_last_scanned_index = idx + 1

                sender = str(row.get("from", "")).strip()
                if sender not in worker_done:
                    continue

                msg_type = str(row.get("type", "")).strip()
                summary = str(row.get("summary", "")).strip().lower()
                meta = agent_loop.parse_meta(row.get("meta"))
                source = str(meta.get("source", "")).strip().lower()
                if source == "worker-result":
                    continue
                if source == "collab-update" and summary.startswith("peer-"):
                    continue

                if msg_type in {"question", "blocker", "task", "shutdown_request"}:
                    worker_done[sender] = False
                    review_ready_announced = False
                elif msg_type == "message" and summary not in {"worker-run-complete", "worker-run-failed"}:
                    worker_done[sender] = False
                    review_ready_announced = False

            force_lead_scan = bool(LEAD_MAILBOX_SCAN_BATCH > 0 and len(lead_rows) >= LEAD_MAILBOX_SCAN_BATCH)
            if not force_lead_scan:
                lead_last_mention_token = lead_mention_token
            if lead_rows:
                did_work = True

        if not review_ready_announced and all_workers_review_ready(workers, worker_done):
            notify_review_ready(
                fs_path=fs_path,
                bus_path=bus_path,
                db_path=db_path,
                repo=args.repo,
                session=args.session,
                room=args.room,
                lead=lead,
                reviewers=reviewer_names,
                worker_done=worker_done,
            )
            review_ready_announced = True
            did_work = True

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

        time.sleep(
            compute_loop_sleep(
                args=args,
                workers=workers,
                force_lead_scan=force_lead_scan,
                did_work=did_work,
            )
        )

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
    fs_cmd(
        fs_path,
        [
            "runtime-mark",
            "--repo",
            args.repo,
            "--session",
            args.session,
            "--agent",
            "inprocess-hub",
            "--status",
            "terminated",
        ],
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
