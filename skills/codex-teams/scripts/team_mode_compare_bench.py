#!/usr/bin/env python3
"""Benchmark codex-teams in-process-shared runtime profile."""

from __future__ import annotations

import argparse
import json
import os
import signal
import statistics
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
TEAM_CODEX = SCRIPT_DIR / "team_codex.sh"
TEAM_FS = SCRIPT_DIR / "team_fs.py"
MOCK_CODEX = SCRIPT_DIR / "bench_mock_codex.py"


WORKERS = ["worker-1", "worker-2", "worker-3"]
VALID_MODES = {"in-process-shared"}
WORKER_ACK_SUMMARIES = {"work-update", "worker-run-complete", "worker-run-failed"}


class BenchError(RuntimeError):
    pass


def is_worker_ack(msg: dict[str, Any], *, worker: str = "") -> bool:
    sender = str(msg.get("from", "")).strip()
    if worker and sender != worker:
        return False
    if not sender.startswith("worker-"):
        return False

    summary = str(msg.get("summary", "")).strip()
    if summary in WORKER_ACK_SUMMARIES:
        return True

    meta = msg.get("meta")
    if isinstance(meta, dict) and str(meta.get("source", "")).strip() == "worker-result":
        return True

    text = str(msg.get("text", "")).strip()
    return "worker_result state=" in text


def resolve_tmp_root() -> Path:
    raw = os.environ.get("CODEX_BENCH_TMPDIR", "").strip() or os.environ.get("TMPDIR", "").strip()
    candidates: list[Path] = []
    if raw:
        candidates.append(Path(raw).expanduser())
    candidates.append(SCRIPT_DIR.parents[2] / ".tmp")
    candidates.append(Path.cwd() / ".tmp")

    for candidate in candidates:
        text = str(candidate)
        if not text.startswith("/mnt/"):
            continue
        candidate.mkdir(parents=True, exist_ok=True)
        return candidate

    raise BenchError("benchmark tmp dir must be under /mnt/... (set CODEX_BENCH_TMPDIR)")


def run_cmd(
    cmd: list[str],
    *,
    env: dict[str, str],
    cwd: str | None = None,
    check: bool = True,
    timeout_sec: float | None = None,
) -> str:
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=timeout_sec,
    )
    if check and proc.returncode != 0:
        raise BenchError(
            f"command failed rc={proc.returncode}\ncmd={' '.join(cmd)}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )
    return proc.stdout.strip()


def ps_aggregate(pids: list[int], *, env: dict[str, str]) -> dict[str, float]:
    if not pids:
        return {"cpu": 0.0, "rss_kb": 0.0}
    out = run_cmd(
        ["ps", "-p", ",".join(str(pid) for pid in pids), "-o", "pcpu=", "-o", "rss="],
        env=env,
        check=False,
    )
    cpu = 0.0
    rss = 0.0
    for line in out.splitlines():
        parts = [p for p in line.split() if p]
        if len(parts) < 2:
            continue
        try:
            cpu += float(parts[0])
            rss += float(parts[1])
        except ValueError:
            continue
    return {"cpu": cpu, "rss_kb": rss}


def summarize_usage(samples: list[dict[str, float]]) -> dict[str, float]:
    if not samples:
        return {
            "samples": 0.0,
            "cpu_avg": 0.0,
            "cpu_max": 0.0,
            "rss_mb_avg": 0.0,
            "rss_mb_max": 0.0,
        }
    cpu_vals = [x["cpu"] for x in samples]
    rss_vals = [x["rss_kb"] / 1024.0 for x in samples]
    return {
        "samples": float(len(samples)),
        "cpu_avg": float(sum(cpu_vals) / len(cpu_vals)),
        "cpu_max": float(max(cpu_vals)),
        "rss_mb_avg": float(sum(rss_vals) / len(rss_vals)),
        "rss_mb_max": float(max(rss_vals)),
    }


def summarize_latency(latencies: list[float]) -> dict[str, float]:
    if not latencies:
        return {"count": 0.0, "avg_ms": 0.0, "p50_ms": 0.0, "p95_ms": 0.0, "max_ms": 0.0}
    ordered = sorted(latencies)
    p50 = statistics.median(ordered)
    p95_idx = min(len(ordered) - 1, max(0, int(round(len(ordered) * 0.95)) - 1))
    return {
        "count": float(len(latencies)),
        "avg_ms": float(sum(latencies) / len(latencies) * 1000.0),
        "p50_ms": float(p50 * 1000.0),
        "p95_ms": float(ordered[p95_idx] * 1000.0),
        "max_ms": float(max(latencies) * 1000.0),
    }


def init_git_repo(repo: Path, *, env: dict[str, str]) -> None:
    repo.mkdir(parents=True, exist_ok=True)
    run_cmd(["git", "init"], env=env, cwd=str(repo))
    run_cmd(["git", "config", "user.name", "bench"], env=env, cwd=str(repo))
    run_cmd(["git", "config", "user.email", "bench@example.com"], env=env, cwd=str(repo))
    (repo / "README.md").write_text("# bench\n", encoding="utf-8")
    run_cmd(["git", "add", "README.md"], env=env, cwd=str(repo))
    run_cmd(["git", "commit", "-m", "init"], env=env, cwd=str(repo))


def fs_cmd(repo: Path, session: str, args: list[str], *, env: dict[str, str]) -> str:
    cmd = ["python3", str(TEAM_FS), *args, "--repo", str(repo), "--session", session]
    return run_cmd(cmd, env=env)


def mark_lead_read_all(repo: Path, session: str, *, env: dict[str, str]) -> None:
    fs_cmd(repo, session, ["mailbox-mark-read", "--agent", "lead", "--all"], env=env)


def read_lead_unread(repo: Path, session: str, *, env: dict[str, str]) -> list[dict[str, Any]]:
    out = fs_cmd(repo, session, ["mailbox-read", "--agent", "lead", "--unread", "--json", "--limit", "100000"], env=env)
    try:
        decoded = json.loads(out)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, list):
        return []
    rows: list[dict[str, Any]] = []
    for item in decoded:
        if isinstance(item, dict):
            rows.append(item)
    return rows


def send_task(repo: Path, session: str, *, worker: str, idx: int, env: dict[str, str]) -> None:
    run_cmd(
        [
            "bash",
            str(TEAM_CODEX),
            "sendmessage",
            "--repo",
            str(repo),
            "--session",
            session,
            "--type",
            "task",
            "--from",
            "lead",
            "--to",
            worker,
            "--summary",
            f"bench-task-{idx}-{worker}",
            "--content",
            f"benchmark task idx={idx} worker={worker}",
        ],
        env=env,
    )


def wait_for_worker_ack(
    repo: Path,
    session: str,
    *,
    worker: str,
    timeout_sec: float,
    env: dict[str, str],
) -> float | None:
    start = time.time()
    deadline = start + timeout_sec
    while time.time() < deadline:
        unread = read_lead_unread(repo, session, env=env)
        for msg in unread:
            if is_worker_ack(msg, worker=worker):
                return time.time() - start
        time.sleep(0.05)
    return None


def wait_for_burst_acks(
    repo: Path,
    session: str,
    *,
    expected: int,
    timeout_sec: float,
    env: dict[str, str],
) -> tuple[float | None, int]:
    start = time.time()
    deadline = start + timeout_sec
    observed = 0
    while time.time() < deadline:
        unread = read_lead_unread(repo, session, env=env)
        observed = sum(1 for msg in unread if is_worker_ack(msg))
        if observed >= expected:
            return time.time() - start, observed
        time.sleep(0.05)
    return None, observed


def wait_for_worker_ack_with_sampling(
    repo: Path,
    session: str,
    *,
    worker: str,
    mode: str,
    timeout_sec: float,
    sample_interval_sec: float,
    samples: list[dict[str, float]],
    env: dict[str, str],
) -> float | None:
    start = time.time()
    deadline = start + timeout_sec
    next_sample = start
    while time.time() < deadline:
        now = time.time()
        if now >= next_sample:
            pids = mode_pids(repo, session, mode, env=env)
            samples.append(ps_aggregate(pids, env=env))
            next_sample = now + sample_interval_sec

        unread = read_lead_unread(repo, session, env=env)
        for msg in unread:
            if is_worker_ack(msg, worker=worker):
                return time.time() - start
        time.sleep(0.05)
    return None


def mode_pids(repo: Path, session: str, mode: str, *, env: dict[str, str]) -> list[int]:
    pids: set[int] = set()
    out = fs_cmd(repo, session, ["runtime-list", "--json"], env=env)
    try:
        rt = json.loads(out)
    except json.JSONDecodeError:
        rt = {}
    if isinstance(rt, dict):
        agents = rt.get("agents", {})
        if isinstance(agents, dict):
            for rec in agents.values():
                if not isinstance(rec, dict):
                    continue
                pid = int(rec.get("pid", 0) or 0)
                if pid > 0:
                    pids.add(pid)

    alive: list[int] = []
    for pid in sorted(pids):
        try:
            os.kill(pid, 0)
        except OSError:
            continue
        alive.append(pid)
    return alive


def wait_mode_ready(repo: Path, session: str, mode: str, *, env: dict[str, str], timeout_sec: float = 30.0) -> None:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        pids = mode_pids(repo, session, mode, env=env)
        if len(pids) >= 1:
            return
        time.sleep(0.2)
    raise BenchError(f"mode not ready within timeout: mode={mode}")


def run_one_mode(
    mode: str,
    *,
    idle_sec: float,
    throughput_tasks: int,
    sample_interval_sec: float,
    ack_timeout_sec: float,
    env: dict[str, str],
) -> dict[str, Any]:
    if mode not in VALID_MODES:
        raise BenchError(f"unsupported mode: {mode}")

    tmp_root = resolve_tmp_root()

    repo = Path(tempfile.mkdtemp(prefix=f"codex_mode_{mode.replace('-', '_')}_", dir=str(tmp_root)))
    session = f"bench-{mode.replace('-', '')}-{int(time.time() * 1000) % 1000000}"

    mode_env = dict(env)
    mode_env["PYTHONDONTWRITEBYTECODE"] = "1"
    mode_env["CODEX_EXPERIMENTAL_AGENT_TEAMS"] = "1"
    mode_env["CODEX_TEAMS_GATE_TENGU_AMBER_FLINT"] = "1"
    mode_env["CODEX_TEAMMATE_COMMAND"] = str(MOCK_CODEX)
    mode_env["CODEX_BENCH_REPO"] = str(repo)
    mode_env["CODEX_BENCH_SESSION"] = session
    mode_env["CODEX_BENCH_FS"] = str(TEAM_FS)
    mode_env["CODEX_BENCH_LEAD"] = "lead"
    mode_env["CODEX_BENCH_ENABLE_RESPONDER"] = "1"
    mode_env["CODEX_BENCH_EXEC_SLEEP_MS"] = "80"
    mode_env["CODEX_BENCH_TMUX_LOOP_SLEEP_MS"] = "0"

    try:
        init_git_repo(repo, env=mode_env)
        run_cmd(["bash", str(TEAM_CODEX), "setup", "--repo", str(repo)], env=mode_env)
        run_cmd(
            [
                "bash",
                str(TEAM_CODEX),
                "run",
                "--repo",
                str(repo),
                "--session",
                session,
                "--task",
                f"benchmark bootstrap mode={mode}",
                "--teammate-mode",
                mode,
                "--no-auto-delegate",
            ],
            env=mode_env,
        )

        wait_mode_ready(repo, session, mode, env=mode_env)
        time.sleep(1.0)

        idle_samples: list[dict[str, float]] = []
        idle_end = time.time() + idle_sec
        while time.time() < idle_end:
            pids = mode_pids(repo, session, mode, env=mode_env)
            idle_samples.append(ps_aggregate(pids, env=mode_env))
            time.sleep(sample_interval_sec)

        latencies: list[float] = []
        for idx, worker in enumerate(WORKERS, start=1):
            mark_lead_read_all(repo, session, env=mode_env)
            send_task(repo, session, worker=worker, idx=idx, env=mode_env)
            latency = wait_for_worker_ack(repo, session, worker=worker, timeout_sec=ack_timeout_sec, env=mode_env)
            if latency is not None:
                latencies.append(latency)
            mark_lead_read_all(repo, session, env=mode_env)

        seq_samples: list[dict[str, float]] = []
        seq_latencies: list[float] = []
        seq_start = time.time()
        seq_acked = 0
        for idx in range(throughput_tasks):
            worker = WORKERS[idx % len(WORKERS)]
            mark_lead_read_all(repo, session, env=mode_env)
            send_task(repo, session, worker=worker, idx=2000 + idx, env=mode_env)
            latency = wait_for_worker_ack_with_sampling(
                repo,
                session,
                worker=worker,
                mode=mode,
                timeout_sec=ack_timeout_sec,
                sample_interval_sec=sample_interval_sec,
                samples=seq_samples,
                env=mode_env,
            )
            if latency is None:
                break
            seq_latencies.append(latency)
            seq_acked += 1
            mark_lead_read_all(repo, session, env=mode_env)

        seq_elapsed = time.time() - seq_start
        seq_throughput = float(seq_acked) / seq_elapsed if seq_elapsed > 0 else 0.0

        mode_result: dict[str, Any] = {
            "mode": mode,
            "runtime_processes_last": len(mode_pids(repo, session, mode, env=mode_env)),
            "idle_usage": summarize_usage(idle_samples),
            "single_task_latency": summarize_latency(latencies),
            "sequential_throughput": {
                "sent": throughput_tasks,
                "acked": seq_acked,
                "elapsed_sec": seq_elapsed,
                "throughput_task_per_sec": seq_throughput,
                "latency": summarize_latency(seq_latencies),
                "usage": summarize_usage(seq_samples),
            },
            "session": session,
            "repo": str(repo),
        }
        return mode_result
    finally:
        run_cmd(
            [
                "bash",
                str(TEAM_CODEX),
                "teamdelete",
                "--repo",
                str(repo),
                "--session",
                session,
                "--force",
            ],
            env=mode_env,
            check=False,
            timeout_sec=20,
        )
        subprocess.run(["rm", "-rf", str(repo)], check=False)


def main() -> int:
    parser = argparse.ArgumentParser(description="Profile codex-teams in-process-shared runtime performance")
    parser.add_argument("--modes", default="in-process-shared")
    parser.add_argument("--idle-sec", type=float, default=8.0)
    parser.add_argument("--throughput-tasks", type=int, default=12)
    parser.add_argument("--sample-interval-sec", type=float, default=0.5)
    parser.add_argument("--ack-timeout-sec", type=float, default=30.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    selected = [m.strip() for m in args.modes.split(",") if m.strip()]
    if not selected:
        raise SystemExit("no modes selected")
    for mode in selected:
        if mode not in VALID_MODES:
            raise SystemExit(f"unsupported mode: {mode}")
    if args.idle_sec <= 0:
        raise SystemExit("--idle-sec must be > 0")
    if args.throughput_tasks <= 0:
        raise SystemExit("--throughput-tasks must be > 0")
    if args.sample_interval_sec <= 0:
        raise SystemExit("--sample-interval-sec must be > 0")
    if args.ack_timeout_sec <= 0:
        raise SystemExit("--ack-timeout-sec must be > 0")

    env = dict(os.environ)
    all_results: list[dict[str, Any]] = []
    started = time.time()
    for mode in selected:
        all_results.append(
            run_one_mode(
                mode,
                idle_sec=args.idle_sec,
                throughput_tasks=args.throughput_tasks,
                sample_interval_sec=args.sample_interval_sec,
                ack_timeout_sec=args.ack_timeout_sec,
                env=env,
            )
        )

    payload = {
        "config": {
            "modes": selected,
            "idle_sec": args.idle_sec,
            "throughput_tasks": args.throughput_tasks,
            "sample_interval_sec": args.sample_interval_sec,
            "ack_timeout_sec": args.ack_timeout_sec,
            "mock_codex": str(MOCK_CODEX),
        },
        "elapsed_sec": time.time() - started,
        "results": all_results,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
