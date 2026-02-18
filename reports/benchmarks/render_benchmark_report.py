#!/usr/bin/env python3
"""Render benchmark plots and a markdown summary report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def write_resource_plot(mode_result: dict, soak_results: dict, out_path: Path) -> None:
    labels = ["mode-idle", "mode-seq", "soak-idle", "soak-burst"]
    cpu_vals = [
        float(mode_result["idle_usage"]["cpu_avg"]),
        float(mode_result["sequential_throughput"]["usage"]["cpu_avg"]),
        float(soak_results["idle"]["cpu_avg"]),
        float(soak_results["burst"]["cpu_avg"]),
    ]
    rss_vals = [
        float(mode_result["idle_usage"]["rss_mb_avg"]),
        float(mode_result["sequential_throughput"]["usage"]["rss_mb_avg"]),
        float(soak_results["idle"]["rss_mb_avg"]),
        float(soak_results["burst"]["rss_mb_avg"]),
    ]

    fig, axes = plt.subplots(1, 2, figsize=(12, 4.8))

    axes[0].bar(labels, cpu_vals, color=["#0B6E4F", "#08A045", "#F28E2B", "#E15759"])
    axes[0].set_title("CPU Average (%)")
    axes[0].set_ylabel("CPU %")
    axes[0].tick_params(axis="x", rotation=20)

    axes[1].bar(labels, rss_vals, color=["#4E79A7", "#59A14F", "#EDC948", "#B07AA1"])
    axes[1].set_title("RSS Average (MB)")
    axes[1].set_ylabel("MB")
    axes[1].tick_params(axis="x", rotation=20)

    fig.tight_layout()
    fig.savefig(out_path, dpi=170)
    plt.close(fig)


def write_latency_plot(mode_result: dict, out_path: Path) -> None:
    single = mode_result["single_task_latency"]
    seq = mode_result["sequential_throughput"]["latency"]
    labels = [
        "single-avg",
        "single-p95",
        "single-max",
        "seq-avg",
        "seq-p95",
        "seq-max",
    ]
    vals = [
        float(single["avg_ms"]),
        float(single["p95_ms"]),
        float(single["max_ms"]),
        float(seq["avg_ms"]),
        float(seq["p95_ms"]),
        float(seq["max_ms"]),
    ]

    fig, ax = plt.subplots(figsize=(10.5, 4.8))
    ax.bar(labels, vals, color=["#76B7B2", "#76B7B2", "#76B7B2", "#E15759", "#E15759", "#E15759"])
    ax.set_title("Latency Profile (ms)")
    ax.set_ylabel("ms")
    ax.tick_params(axis="x", rotation=20)
    fig.tight_layout()
    fig.savefig(out_path, dpi=170)
    plt.close(fig)


def write_throughput_plot(mode_result: dict, out_path: Path) -> None:
    seq = mode_result["sequential_throughput"]
    labels = ["sent", "acked", "throughput(task/s)"]
    vals = [float(seq["sent"]), float(seq["acked"]), float(seq["throughput_task_per_sec"])]

    fig, ax = plt.subplots(figsize=(8.5, 4.5))
    ax.bar(labels, vals, color=["#4E79A7", "#59A14F", "#F28E2B"])
    ax.set_title("Sequential Throughput")
    ax.set_ylabel("count / task/s")
    fig.tight_layout()
    fig.savefig(out_path, dpi=170)
    plt.close(fig)


def write_backlog_plot(soak_results: dict, out_path: Path) -> None:
    workers = soak_results.get("worker_unread_totals", {})
    labels = list(workers.keys()) + ["lead-unread-updates"]
    vals = [float(workers.get(k, 0)) for k in workers.keys()]
    vals.append(float(soak_results.get("lead_work_update_unread", 0)))

    fig, ax = plt.subplots(figsize=(9.5, 4.5))
    ax.bar(labels, vals, color=["#9C755F", "#BAB0AC", "#B07AA1", "#E15759"])
    ax.set_title("Mailbox Backlog Snapshot")
    ax.set_ylabel("unread count")
    ax.tick_params(axis="x", rotation=20)
    fig.tight_layout()
    fig.savefig(out_path, dpi=170)
    plt.close(fig)


def write_report(
    *,
    mode_json_path: Path,
    soak_json_path: Path,
    out_report_path: Path,
    mode_data: dict,
    mode_result: dict,
    soak_data: dict,
) -> None:
    seq = mode_result["sequential_throughput"]
    single = mode_result["single_task_latency"]
    soak_results = soak_data["results"]

    report = f"""# codex-teams Benchmark Report

## Inputs
- mode benchmark JSON: `{mode_json_path}`
- soak benchmark JSON: `{soak_json_path}`

## Key Metrics
- mode elapsed: {float(mode_data.get("elapsed_sec", 0.0)):.3f}s
- soak elapsed: {float(soak_data.get("elapsed_sec", 0.0)):.3f}s
- mode runtime process(es) last observed: {float(mode_result.get("runtime_processes_last", 0)):.0f}
- single-task latency avg/p95/max: {float(single["avg_ms"]):.2f} / {float(single["p95_ms"]):.2f} / {float(single["max_ms"]):.2f} ms
- sequential throughput: sent={int(seq["sent"])}, acked={int(seq["acked"])}, throughput={float(seq["throughput_task_per_sec"]):.3f} task/s
- mode CPU avg (idle/seq): {float(mode_result["idle_usage"]["cpu_avg"]):.3f}% / {float(seq["usage"]["cpu_avg"]):.3f}%
- soak CPU avg (idle/burst): {float(soak_results["idle"]["cpu_avg"]):.3f}% / {float(soak_results["burst"]["cpu_avg"]):.3f}%
- soak RSS avg (idle/burst): {float(soak_results["idle"]["rss_mb_avg"]):.3f} / {float(soak_results["burst"]["rss_mb_avg"]):.3f} MB
- soak burst sent: {int(soak_results["burst_sent"])}
- soak lead unread worker updates: {int(soak_results["lead_work_update_unread"])}
- soak worker unread totals: {json.dumps(soak_results.get("worker_unread_totals", {}), ensure_ascii=False)}

## Plots
![Resource Usage](plots/resource_cpu_rss.png)
![Latency Profile](plots/latency_profile_ms.png)
![Throughput](plots/throughput_summary.png)
![Mailbox Backlog](plots/mailbox_backlog.png)
"""
    out_report_path.write_text(report, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Render codex-teams benchmark plots/report")
    parser.add_argument("--mode-json", required=True)
    parser.add_argument("--soak-json", required=True)
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()

    mode_json_path = Path(args.mode_json)
    soak_json_path = Path(args.soak_json)
    out_dir = Path(args.out_dir)
    plots_dir = out_dir / "plots"
    plots_dir.mkdir(parents=True, exist_ok=True)

    mode_data = load_json(mode_json_path)
    soak_data = load_json(soak_json_path)
    mode_result = mode_data["results"][0]
    soak_results = soak_data["results"]

    write_resource_plot(mode_result, soak_results, plots_dir / "resource_cpu_rss.png")
    write_latency_plot(mode_result, plots_dir / "latency_profile_ms.png")
    write_throughput_plot(mode_result, plots_dir / "throughput_summary.png")
    write_backlog_plot(soak_results, plots_dir / "mailbox_backlog.png")

    write_report(
        mode_json_path=mode_json_path,
        soak_json_path=soak_json_path,
        out_report_path=out_dir / "benchmark-report.md",
        mode_data=mode_data,
        mode_result=mode_result,
        soak_data=soak_data,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
