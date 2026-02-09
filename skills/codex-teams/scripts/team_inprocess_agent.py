#!/usr/bin/env python3
"""In-process teammate loop for codex-teams.

Runs as a background process managed by team_codex.sh.
Consumes file-based mailbox messages and coordinates status over team_bus.py.
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
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import team_fs  # noqa: E402


STOP = False
PERMISSION_MODES = {"default", "acceptEdits", "bypassPermissions", "plan", "delegate", "dontAsk"}
SYSTEM_SENDER_NAMES = {"system", "monitor", "orchestrator"}


def on_signal(signum: int, _frame: object) -> None:
    global STOP
    STOP = True


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


def bus_cmd(bus_path: Path, db_path: Path, args: list[str]) -> None:
    cmd = [sys.executable, str(bus_path), "--db", str(db_path), *args]
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def fs_cmd(fs_path: Path, args: list[str]) -> tuple[int, str]:
    cmd = [sys.executable, str(fs_path), *args]
    proc = subprocess.run(cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return proc.returncode, proc.stdout or ""


def summarize_output(raw: str, limit: int = 220) -> str:
    text = " ".join(raw.strip().split())
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def codex_exec_base(codex_bin: str, permission_mode: str) -> list[str]:
    mode = str(permission_mode or "default").strip()
    cmd = [codex_bin, "exec"]
    if mode in {"bypassPermissions", "dontAsk"}:
        cmd.append("--dangerously-bypass-approvals-and-sandbox")
    elif mode == "plan":
        cmd.extend(["--sandbox", "read-only"])
    else:
        cmd.append("--full-auto")
    return cmd


def resolve_lead(cfg: dict) -> str:
    return team_fs.lead_name(cfg)


def parse_meta(raw_meta: object) -> dict:
    if isinstance(raw_meta, dict):
        return raw_meta
    if isinstance(raw_meta, str):
        try:
            decoded = json.loads(raw_meta)
        except json.JSONDecodeError:
            return {}
        return decoded if isinstance(decoded, dict) else {}
    return {}


def dispatch_message(
    *,
    fs_path: Path,
    args: argparse.Namespace,
    msg_type: str,
    sender: str,
    recipient: str,
    content: str,
    summary: str = "",
    request_id: str = "",
    approve: bool | None = None,
) -> None:
    cmd = [
        "dispatch",
        "--repo",
        args.repo,
        "--session",
        args.session,
        "--type",
        msg_type,
        "--from",
        sender,
        "--recipient",
        recipient,
        "--content",
        content,
        "--summary",
        summary,
    ]
    if request_id:
        cmd.extend(["--request-id", request_id])
    if approve is not None:
        cmd.extend(["--approve", "true" if approve else "false"])
    fs_cmd(fs_path, cmd)


def collect_collaboration_targets(messages: list[dict], *, self_agent: str) -> dict[str, set[str]]:
    targets: dict[str, set[str]] = {}
    for msg in messages:
        sender = str(msg.get("from", "")).strip()
        if not sender or sender == self_agent or sender in SYSTEM_SENDER_NAMES:
            continue
        msg_type = str(msg.get("type", "message")).strip() or "message"
        bucket = targets.setdefault(sender, set())
        bucket.add(msg_type)
    return targets


def merge_collaboration_targets(into: dict[str, set[str]], updates: dict[str, set[str]]) -> None:
    for sender, kinds in updates.items():
        bucket = into.setdefault(sender, set())
        for item in kinds:
            bucket.add(item)


def emit_collaboration_updates(
    *,
    fs_path: Path,
    bus_path: Path,
    db_path: Path,
    args: argparse.Namespace,
    lead: str,
    sender: str,
    targets: dict[str, set[str]],
    result_body: str,
    exit_code: int,
) -> None:
    for recipient in sorted(targets.keys()):
        if not recipient or recipient == sender:
            continue
        # Non-lead teammates already report to lead via primary status channel.
        if sender != lead and recipient == lead:
            continue

        source_types = sorted(targets.get(recipient, set()))
        source_types_text = ",".join(source_types) if source_types else "message"

        if exit_code != 0:
            kind = "blocker"
            summary = "peer-blocker"
        elif "question" in source_types:
            kind = "answer"
            summary = "peer-answer"
        else:
            kind = "status"
            summary = "peer-update"

        body = f"collab_update from={sender} source_types={source_types_text} result={result_body}"
        bus_cmd(
            bus_path,
            db_path,
            [
                "send",
                "--room",
                args.room,
                "--from",
                sender,
                "--to",
                recipient,
                "--kind",
                kind,
                "--body",
                body,
            ],
        )
        dispatch_message(
            fs_path=fs_path,
            args=args,
            msg_type=kind,
            sender=sender,
            recipient=recipient,
            content=body,
            summary=summary,
        )


def fs_control_respond(
    *,
    fs_path: Path,
    args: argparse.Namespace,
    request_id: str,
    responder: str,
    approve: bool,
    body: str,
    recipient: str,
    req_type: str,
) -> None:
    cmd = [
        "control-respond",
        "--repo",
        args.repo,
        "--session",
        args.session,
        "--request-id",
        request_id,
        "--from",
        responder,
        "--body",
        body,
        "--to",
        recipient,
        "--req-type",
        req_type,
        "--approve" if approve else "--reject",
    ]
    fs_cmd(fs_path, cmd)


def handle_control_messages(
    *,
    args: argparse.Namespace,
    fs_path: Path,
    bus_path: Path,
    db_path: Path,
    messages: list[dict],
    cfg: dict,
) -> tuple[bool, list[dict]]:
    """Return (should_shutdown, work_messages)."""
    should_shutdown = False
    work_messages: list[dict] = []
    lead = resolve_lead(cfg)

    for msg in messages:
        mtype = str(msg.get("type", ""))
        sender = str(msg.get("from", ""))
        request_id = str(msg.get("request_id", ""))
        text = str(msg.get("text", ""))
        summary = str(msg.get("summary", ""))
        meta = parse_meta(msg.get("meta"))

        if mtype == "shutdown_request":
            response_text = "shutdown approved"
            if request_id:
                bus_cmd(
                    bus_path,
                    db_path,
                    [
                        "control-respond",
                        "--request-id",
                        request_id,
                        "--from",
                        args.agent,
                        "--approve",
                        "--body",
                        response_text,
                    ],
                )
                fs_control_respond(
                    fs_path=fs_path,
                    args=args,
                    request_id=request_id,
                    responder=args.agent,
                    approve=True,
                    body=response_text,
                    recipient=sender or lead,
                    req_type="shutdown",
                )
            else:
                # Compatibility path for direct mailbox shutdown messages without request ids.
                dispatch_message(
                    fs_path=fs_path,
                    args=args,
                    msg_type="shutdown_response",
                    sender=args.agent,
                    recipient=sender or lead,
                    content=response_text,
                    request_id=request_id,
                    approve=True,
                )
            bus_cmd(
                bus_path,
                db_path,
                [
                    "send",
                    "--room",
                    args.room,
                    "--from",
                    args.agent,
                    "--to",
                    "all",
                    "--kind",
                    "status",
                    "--body",
                    "shutdown requested; terminating agent loop",
                ],
            )
            should_shutdown = True
            continue

        if mtype == "mode_set_request":
            requested_mode = str(meta.get("mode", "")).strip() or text.strip()
            approved = requested_mode in PERMISSION_MODES
            response_text = "mode updated"
            if approved:
                args.permission_mode = requested_mode
                rc, _ = fs_cmd(
                    fs_path,
                    [
                        "member-mode",
                        "--repo",
                        args.repo,
                        "--session",
                        args.session,
                        "--ident",
                        args.agent,
                        "--mode",
                        requested_mode,
                    ],
                )
                if rc != 0:
                    approved = False
                    response_text = f"failed to set mode={requested_mode}"
            else:
                response_text = f"unsupported mode={requested_mode}"

            if request_id:
                bus_cmd(
                    bus_path,
                    db_path,
                    [
                        "control-respond",
                        "--request-id",
                        request_id,
                        "--from",
                        args.agent,
                        "--approve" if approved else "--reject",
                        "--body",
                        response_text,
                    ],
                )
                fs_control_respond(
                    fs_path=fs_path,
                    args=args,
                    request_id=request_id,
                    responder=args.agent,
                    approve=approved,
                    body=response_text,
                    recipient=sender or lead,
                    req_type="mode_set",
                )
            else:
                dispatch_message(
                    fs_path=fs_path,
                    args=args,
                    msg_type="mode_set_response",
                    sender=args.agent,
                    recipient=sender or lead,
                    content=response_text,
                    summary=summary,
                    request_id=request_id,
                    approve=approved,
                )
            bus_cmd(
                bus_path,
                db_path,
                [
                    "send",
                    "--room",
                    args.room,
                    "--from",
                    args.agent,
                    "--to",
                    "all",
                    "--kind",
                    "status",
                    "--body",
                    f"mode_set handled mode={requested_mode} approved={str(approved).lower()}",
                ],
            )
            if approved:
                bus_cmd(
                    bus_path,
                    db_path,
                    [
                        "send",
                        "--room",
                        args.room,
                        "--from",
                        args.agent,
                        "--to",
                        "all",
                        "--kind",
                        "status",
                        "--body",
                        f"tengu_teammate_mode_changed mode={requested_mode}",
                    ],
                )
            continue

        if mtype in {
            "plan_approval_response",
            "permission_response",
            "shutdown_response",
            "shutdown_approved",
            "shutdown_rejected",
            "mode_set_response",
        }:
            summary = summarize_output(text, limit=140) or mtype
            bus_cmd(
                bus_path,
                db_path,
                [
                    "send",
                    "--room",
                    args.room,
                    "--from",
                    args.agent,
                    "--to",
                    "all",
                    "--kind",
                    "status",
                    "--body",
                    f"received {mtype} from={sender} summary={summary}",
                ],
            )
            continue

        if mtype in {"plan_approval_request", "permission_request"}:
            req_label = summarize_output(text, limit=140) or mtype
            bus_cmd(
                bus_path,
                db_path,
                [
                    "send",
                    "--room",
                    args.room,
                    "--from",
                    args.agent,
                    "--to",
                    lead,
                    "--kind",
                    "status",
                    "--body",
                    f"received {mtype} from={sender} summary={req_label}",
                ],
            )
            continue

        work_messages.append(msg)

    return should_shutdown, work_messages


def main() -> int:
    parser = argparse.ArgumentParser(description="codex-teams in-process teammate loop")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--room", default="main")
    parser.add_argument("--agent", required=True)
    parser.add_argument("--role", default="worker")
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--profile", default="pair")
    parser.add_argument("--model", default="")
    parser.add_argument("--codex-bin", default="codex")
    parser.add_argument("--poll-ms", type=int, default=500)
    parser.add_argument("--idle-ms", type=int, default=12000)
    parser.add_argument("--permission-mode", default="default")
    parser.add_argument("--plan-mode-required", action="store_true")
    parser.add_argument("--initial-task", default="")
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    fs_path = SCRIPT_DIR / "team_fs.py"
    bus_path = SCRIPT_DIR / "team_bus.py"
    db_path = Path(args.repo).resolve() / ".codex-teams" / args.session / "bus.sqlite"

    paths = team_fs.resolve_paths(args.repo, args.session)
    cfg = team_fs.read_config(paths)
    lead = resolve_lead(cfg)
    team_context_prompt = (
        "# Agent Teammate Communication\n"
        "You are running as an agent in a team. Use codex-teams sendmessage types "
        "`message` and `broadcast` for team communication.\n\n"
        "# Team Coordination\n"
        f"You are teammate `{args.agent}` in team `{args.session}`.\n"
        f"Team config: {paths.config}\n"
        f"Task list: {paths.tasks}\n"
        f"Team leader: {lead}\n"
    )

    fs_cmd(
        fs_path,
        [
            "runtime-set",
            "--repo",
            args.repo,
            "--session",
            args.session,
            "--agent",
            args.agent,
            "--backend",
            "in-process",
            "--status",
            "running",
            "--pid",
            str(os.getpid()),
            "--window",
            "in-process",
        ],
    )
    bus_cmd(
        bus_path,
        db_path,
        ["register", "--room", args.room, "--agent", args.agent, "--role", args.role],
    )
    bus_cmd(
        bus_path,
        db_path,
        [
            "send",
            "--room",
            args.room,
            "--from",
            args.agent,
            "--to",
            "all",
            "--kind",
            "status",
            "--body",
            f"online backend=in-process pid={os.getpid()} permission_mode={args.permission_mode}",
        ],
    )

    pending_texts: list[str] = []
    pending_collaboration_targets: dict[str, set[str]] = {}
    if args.initial_task.strip():
        pending_texts.append(args.initial_task.strip())
        bus_cmd(
            bus_path,
            db_path,
            [
                "send",
                "--room",
                args.room,
                "--from",
                args.agent,
                "--to",
                lead,
                "--kind",
                "status",
                "--body",
                "initial task accepted",
            ],
        )

    last_activity = int(time.time() * 1000)
    last_idle_sent = 0

    while not STOP:
        rc, stdout = fs_cmd(
            fs_path,
            [
                "mailbox-read",
                "--repo",
                args.repo,
                "--session",
                args.session,
                "--agent",
                args.agent,
                "--unread",
                "--json",
                "--limit",
                "200",
            ],
        )
        unread: list[dict] = []
        if rc == 0 and stdout.strip():
            try:
                unread = json.loads(stdout)
            except json.JSONDecodeError:
                unread = []

        if unread:
            indexes: list[int] = []
            messages: list[dict] = []
            for item in unread:
                if not isinstance(item, dict):
                    continue
                idx = int(item.get("index", -1))
                if idx >= 0:
                    indexes.append(idx)
                messages.append(item)

            if indexes:
                cmd = [
                    "mailbox-mark-read",
                    "--repo",
                    args.repo,
                    "--session",
                    args.session,
                    "--agent",
                    args.agent,
                ]
                for idx in indexes:
                    cmd.extend(["--index", str(idx)])
                fs_cmd(fs_path, cmd)

            should_shutdown, work_messages = handle_control_messages(
                args=args,
                fs_path=fs_path,
                bus_path=bus_path,
                db_path=db_path,
                messages=messages,
                cfg=cfg,
            )
            if should_shutdown:
                break

            for msg in work_messages:
                text = str(msg.get("text", "")).strip()
                summary = str(msg.get("summary", "")).strip()
                sender = str(msg.get("from", ""))
                if text:
                    pending_texts.append(f"from={sender} summary={summary} text={text}".strip())
            merge_collaboration_targets(
                pending_collaboration_targets,
                collect_collaboration_targets(work_messages, self_agent=args.agent),
            )

            if work_messages:
                last_activity = int(time.time() * 1000)

        if pending_texts:
            prompt = "\n".join(pending_texts)
            prompt = f"{team_context_prompt}\n\n{prompt}"
            pending_texts = []

            cmd = codex_exec_base(args.codex_bin, args.permission_mode)
            if args.model:
                cmd.extend(["-m", args.model])
            if args.profile:
                cmd.extend(["-p", args.profile])
            cmd.extend(["-C", args.cwd, prompt])

            exit_code, run_out = run_cmd(cmd, cwd=args.cwd)
            summary = summarize_output(run_out, limit=220) or "empty output"
            kind = "status" if exit_code == 0 else "blocker"
            body = (
                f"processed prompt exit={exit_code} summary={summary}"
                if exit_code == 0
                else f"codex exec failed exit={exit_code} summary={summary}"
            )

            if args.agent != lead:
                bus_cmd(
                    bus_path,
                    db_path,
                    [
                        "send",
                        "--room",
                        args.room,
                        "--from",
                        args.agent,
                        "--to",
                        lead,
                        "--kind",
                        kind,
                        "--body",
                        body,
                    ],
                )
                dispatch_message(
                    fs_path=fs_path,
                    args=args,
                    msg_type="message",
                    sender=args.agent,
                    recipient=lead,
                    content=body,
                    summary="work-update" if exit_code == 0 else "work-blocker",
                )

            emit_collaboration_updates(
                fs_path=fs_path,
                bus_path=bus_path,
                db_path=db_path,
                args=args,
                lead=lead,
                sender=args.agent,
                targets=pending_collaboration_targets,
                result_body=body,
                exit_code=exit_code,
            )
            pending_collaboration_targets = {}
            last_activity = int(time.time() * 1000)

        now = int(time.time() * 1000)
        if now - last_activity >= args.idle_ms and now - last_idle_sent >= args.idle_ms:
            fs_cmd(
                fs_path,
                [
                    "send-idle",
                    "--repo",
                    args.repo,
                    "--session",
                    args.session,
                    "--agent",
                    args.agent,
                ],
            )
            bus_cmd(
                bus_path,
                db_path,
                [
                    "send",
                    "--room",
                    args.room,
                    "--from",
                    args.agent,
                    "--to",
                    lead,
                    "--kind",
                    "status",
                    "--body",
                    "idle notification sent",
                ],
            )
            last_idle_sent = now

        time.sleep(max(0.1, args.poll_ms / 1000.0))

    fs_cmd(
        fs_path,
        [
            "runtime-mark",
            "--repo",
            args.repo,
            "--session",
            args.session,
            "--agent",
            args.agent,
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
            args.room,
            "--from",
            args.agent,
            "--to",
            "all",
            "--kind",
            "status",
            "--body",
            "offline backend=in-process",
        ],
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
