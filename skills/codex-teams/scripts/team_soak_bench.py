#!/usr/bin/env python3
"""Run codex-teams in-process-shared soak benchmark and print CPU/RAM report."""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import TextIO


SCRIPT_DIR = Path(__file__).resolve().parent
TEAM_FS = SCRIPT_DIR / "team_fs.py"
TEAM_BUS = SCRIPT_DIR / "team_bus.py"
TEAM_HUB = SCRIPT_DIR / "team_inprocess_hub.py"


def run_cmd(cmd: list[str], *, env: dict[str, str], check: bool = True, cwd: str | None = None) -> str:
    proc = subprocess.run(
        cmd,
        check=False,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"command failed rc={proc.returncode}\ncmd={' '.join(cmd)}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )
    return proc.stdout.strip()


def ps_sample(pid: int, *, env: dict[str, str]) -> dict[str, float]:
    out = run_cmd(
        ["ps", "-p", str(pid), "-o", "pcpu=", "-o", "rss=", "-o", "vsz="],
        env=env,
        check=False,
    ).strip()
    if not out:
        return {"cpu": 0.0, "rss_kb": 0.0, "vsz_kb": 0.0}
    parts = [p for p in out.split() if p]
    if len(parts) < 3:
        return {"cpu": 0.0, "rss_kb": 0.0, "vsz_kb": 0.0}
    try:
        return {"cpu": float(parts[0]), "rss_kb": float(parts[1]), "vsz_kb": float(parts[2])}
    except ValueError:
        return {"cpu": 0.0, "rss_kb": 0.0, "vsz_kb": 0.0}


def summarize(samples: list[dict[str, float]]) -> dict[str, float]:
    if not samples:
        return {
            "samples": 0,
            "cpu_avg": 0.0,
            "cpu_max": 0.0,
            "rss_mb_avg": 0.0,
            "rss_mb_max": 0.0,
            "vsz_mb_avg": 0.0,
            "vsz_mb_max": 0.0,
        }
    n = float(len(samples))
    cpu_vals = [s["cpu"] for s in samples]
    rss_mb = [s["rss_kb"] / 1024.0 for s in samples]
    vsz_mb = [s["vsz_kb"] / 1024.0 for s in samples]
    return {
        "samples": int(n),
        "cpu_avg": sum(cpu_vals) / n,
        "cpu_max": max(cpu_vals),
        "rss_mb_avg": sum(rss_mb) / n,
        "rss_mb_max": max(rss_mb),
        "vsz_mb_avg": sum(vsz_mb) / n,
        "vsz_mb_max": max(vsz_mb),
    }


def build_worker_names(workers: int) -> list[str]:
    return [f"worker-{i}" for i in range(1, workers + 1)]


def main() -> int:
    parser = argparse.ArgumentParser(description="codex-teams soak benchmark (in-process-shared)")
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--duration-idle-sec", type=int, default=20)
    parser.add_argument("--duration-burst-sec", type=int, default=20)
    parser.add_argument("--warmup-sec", type=float, default=3.0)
    parser.add_argument("--sample-interval-sec", type=float, default=0.5)
    parser.add_argument("--burst-every-sec", type=float, default=1.0)
    parser.add_argument("--poll-ms", type=int, default=100)
    parser.add_argument("--idle-ms", type=int, default=600000)
    parser.add_argument("--codex-bin", default="/bin/true")
    parser.add_argument("--keep-temp", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.workers < 1:
        raise SystemExit("--workers must be >= 1")
    if args.sample_interval_sec <= 0:
        raise SystemExit("--sample-interval-sec must be > 0")
    if args.warmup_sec < 0:
        raise SystemExit("--warmup-sec must be >= 0")
    if args.duration_idle_sec < 0 or args.duration_burst_sec < 0:
        raise SystemExit("durations must be >= 0")
    if args.burst_every_sec <= 0:
        raise SystemExit("--burst-every-sec must be > 0")

    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"

    temp_repo = Path(tempfile.mkdtemp(prefix="codex_teams_soak_"))
    session = "soak-bench"
    worktrees = temp_repo / ".worktrees"
    worktrees.mkdir(parents=True, exist_ok=True)
    workers = build_worker_names(args.workers)

    for worker in workers:
        (worktrees / worker).mkdir(parents=True, exist_ok=True)

    report: dict[str, object] = {
        "session": session,
        "repo": str(temp_repo),
        "keep_temp": bool(args.keep_temp),
        "workers": workers,
        "config": {
            "duration_idle_sec": args.duration_idle_sec,
            "duration_burst_sec": args.duration_burst_sec,
            "warmup_sec": args.warmup_sec,
            "sample_interval_sec": args.sample_interval_sec,
            "burst_every_sec": args.burst_every_sec,
            "poll_ms": args.poll_ms,
            "idle_ms": args.idle_ms,
            "codex_bin": args.codex_bin,
        },
    }

    hub_proc: subprocess.Popen[str] | None = None
    log_fp: TextIO | None = None
    hub_log = temp_repo / "hub.log"
    burst_sent = 0
    started = time.time()

    try:
        run_cmd(
            [
                "python3",
                str(TEAM_FS),
                "team-create",
                "--repo",
                str(temp_repo),
                "--session",
                session,
                "--team-name",
                session,
                "--lead-name",
                "lead",
                "--replace",
            ],
            env=env,
        )
        for worker in workers:
            run_cmd(
                [
                    "python3",
                    str(TEAM_FS),
                    "member-add",
                    "--repo",
                    str(temp_repo),
                    "--session",
                    session,
                    "--name",
                    worker,
                    "--cwd",
                    str(worktrees / worker),
                    "--backend-type",
                    "in-process-shared",
                ],
                env=env,
            )
        run_cmd(
            [
                "python3",
                str(TEAM_BUS),
                "--db",
                str(temp_repo / ".codex-teams" / session / "bus.sqlite"),
                "init",
            ],
            env=env,
        )

        hub_cmd = [
            "python3",
            str(TEAM_HUB),
            "--repo",
            str(temp_repo),
            "--session",
            session,
            "--room",
            "main",
            "--count",
            str(args.workers),
            "--agents-csv",
            ",".join(workers),
            "--worktrees-root",
            str(worktrees),
            "--codex-bin",
            args.codex_bin,
            "--poll-ms",
            str(args.poll_ms),
            "--idle-ms",
            str(args.idle_ms),
        ]

        log_fp = hub_log.open("w", encoding="utf-8")
        hub_proc = subprocess.Popen(
            hub_cmd,
            stdout=log_fp,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )

        # wait bootstrap + warmup to reduce startup skew in samples.
        time.sleep(1.0 + float(args.warmup_sec))

        idle_samples: list[dict[str, float]] = []
        idle_end = time.time() + float(args.duration_idle_sec)
        while time.time() < idle_end:
            if hub_proc.poll() is not None:
                raise RuntimeError(f"hub exited early rc={hub_proc.returncode}")
            idle_samples.append(ps_sample(hub_proc.pid, env=env))
            time.sleep(args.sample_interval_sec)

        burst_samples: list[dict[str, float]] = []
        burst_end = time.time() + float(args.duration_burst_sec)
        next_burst = time.time()
        while time.time() < burst_end:
            if hub_proc.poll() is not None:
                raise RuntimeError(f"hub exited early rc={hub_proc.returncode}")
            now = time.time()
            if now >= next_burst:
                target = random.choice(workers)
                run_cmd(
                    [
                        "python3",
                        str(TEAM_FS),
                        "dispatch",
                        "--repo",
                        str(temp_repo),
                        "--session",
                        session,
                        "--type",
                        "task",
                        "--from",
                        "lead",
                        "--recipient",
                        target,
                        "--summary",
                        f"soak-{burst_sent}",
                        "--content",
                        f"soak ping {burst_sent}",
                    ],
                    env=env,
                )
                burst_sent += 1
                next_burst = now + args.burst_every_sec
            burst_samples.append(ps_sample(hub_proc.pid, env=env))
            time.sleep(args.sample_interval_sec)

        lead_unread_out = run_cmd(
            [
                "python3",
                str(TEAM_FS),
                "mailbox-read",
                "--repo",
                str(temp_repo),
                "--session",
                session,
                "--agent",
                "lead",
                "--unread",
                "--json",
                "--limit",
                "100000",
            ],
            env=env,
        )
        worker_unread_totals: dict[str, int] = {}
        for worker in workers:
            worker_out = run_cmd(
                [
                    "python3",
                    str(TEAM_FS),
                    "mailbox-read",
                    "--repo",
                    str(temp_repo),
                    "--session",
                    session,
                    "--agent",
                    worker,
                    "--unread",
                    "--json",
                    "--limit",
                    "100000",
                ],
                env=env,
            )
            try:
                worker_unread_totals[worker] = len(json.loads(worker_out))
            except json.JSONDecodeError:
                worker_unread_totals[worker] = -1

        try:
            lead_unread = json.loads(lead_unread_out)
            lead_work_updates = sum(1 for m in lead_unread if str(m.get("summary", "")) == "work-update")
        except json.JSONDecodeError:
            lead_work_updates = -1

        report["results"] = {
            "idle": summarize(idle_samples),
            "burst": summarize(burst_samples),
            "burst_sent": burst_sent,
            "lead_work_update_unread": lead_work_updates,
            "worker_unread_totals": worker_unread_totals,
        }

        elapsed = time.time() - started
        report["elapsed_sec"] = elapsed

        if args.json:
            print(json.dumps(report, ensure_ascii=False))
        else:
            idle = report["results"]["idle"]  # type: ignore[index]
            burst = report["results"]["burst"]  # type: ignore[index]
            print(f"repo={temp_repo}")
            print(f"elapsed_sec={elapsed:.2f}")
            print(
                f"idle cpu_avg={idle['cpu_avg']:.3f}% cpu_max={idle['cpu_max']:.3f}% rss_mb_avg={idle['rss_mb_avg']:.2f} rss_mb_max={idle['rss_mb_max']:.2f}"  # type: ignore[index]
            )
            print(
                f"burst cpu_avg={burst['cpu_avg']:.3f}% cpu_max={burst['cpu_max']:.3f}% rss_mb_avg={burst['rss_mb_avg']:.2f} rss_mb_max={burst['rss_mb_max']:.2f}"  # type: ignore[index]
            )
            print(f"burst_sent={report['results']['burst_sent']}")  # type: ignore[index]
            print(f"lead_work_update_unread={report['results']['lead_work_update_unread']}")  # type: ignore[index]
            print("worker_unread_totals=" + json.dumps(report["results"]["worker_unread_totals"], ensure_ascii=False))  # type: ignore[index]
            print(f"hub_log={hub_log}")
            if not args.keep_temp:
                print("temp_artifacts=removed (use --keep-temp to retain repo/hub_log)")
        return 0
    finally:
        if hub_proc is not None and hub_proc.poll() is None:
            hub_proc.send_signal(signal.SIGTERM)
            try:
                hub_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                hub_proc.kill()
                hub_proc.wait(timeout=3)
        if log_fp is not None and not log_fp.closed:
            log_fp.close()
        if not args.keep_temp:
            shutil.rmtree(temp_repo, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
