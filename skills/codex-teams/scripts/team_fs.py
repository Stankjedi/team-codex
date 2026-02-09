#!/usr/bin/env python3
"""Filesystem state core for codex-teams.

Provides Claude Teams-like local artifacts:
- config.json (team model)
- inboxes/<agent>.json (file mailbox with locking)
- state.json (UI/runtime state snapshot)
- runtime.json (spawned teammate process records)
"""

from __future__ import annotations

import argparse
import copy
import fcntl
import json
import os
import shutil
import signal
import sys
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

COLOR_PALETTE = ["red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan"]
TMUX_BORDER_MAP = {
    "red": "red",
    "blue": "blue",
    "green": "green",
    "yellow": "yellow",
    "purple": "magenta",
    "orange": "colour208",
    "pink": "colour205",
    "cyan": "cyan",
}

MESSAGE_TYPES = {
    "message",
    "broadcast",
    "shutdown_request",
    "shutdown_response",
    "shutdown_approved",
    "shutdown_rejected",
    "plan_approval_request",
    "plan_approval_response",
    "permission_request",
    "permission_response",
    "mode_set_request",
    "mode_set_response",
    "status",
    "task",
    "question",
    "answer",
    "blocker",
    "idle_notification",
    "system",
}

DEFAULT_STATE = {
    "teamContext": None,
    "inbox": {"messages": []},
    "workerSandboxPermissions": {"queue": [], "selectedIndex": 0},
    "expandedView": "none",
    "selectedIPAgentIndex": -1,
    "viewSelectionMode": "none",
    "viewingAgentTaskId": None,
}


@dataclass
class FsPaths:
    repo: Path
    session: str
    root: Path
    config: Path
    team_legacy: Path
    inboxes: Path
    tasks: Path
    state: Path
    runtime: Path
    control: Path


def utc_now_iso_ms() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def now_ms() -> int:
    return int(time.time() * 1000)


def deep_copy(v: Any) -> Any:
    return copy.deepcopy(v)


def sanitize_team_name(name: str) -> str:
    out = "".join(ch if ch.isalnum() or ch in {"-", "_", "."} else "-" for ch in name.strip())
    while "--" in out:
        out = out.replace("--", "-")
    out = out.strip("-_")
    return out or "team"


def make_agent_id(agent_name: str, team_name: str) -> str:
    return f"{agent_name}@{team_name}"


def assign_color(index: int) -> str:
    return COLOR_PALETTE[index % len(COLOR_PALETTE)]


def color_to_tmux_border(color: str) -> str:
    return TMUX_BORDER_MAP.get(color, "default")


def parse_json_object(raw: str | None) -> dict[str, Any]:
    if raw is None or raw == "":
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit("expected JSON object")
    return value


def resolve_paths(repo: str, session: str) -> FsPaths:
    repo_path = Path(repo).expanduser().resolve()
    root = repo_path / ".codex-teams" / session
    return FsPaths(
        repo=repo_path,
        session=session,
        root=root,
        config=root / "config.json",
        team_legacy=root / "team.json",
        inboxes=root / "inboxes",
        tasks=root / "tasks",
        state=root / "state.json",
        runtime=root / "runtime.json",
        control=root / "control.json",
    )


def ensure_dirs(p: FsPaths) -> None:
    p.root.mkdir(parents=True, exist_ok=True)
    p.inboxes.mkdir(parents=True, exist_ok=True)
    p.tasks.mkdir(parents=True, exist_ok=True)


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return deep_copy(default)
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return deep_copy(default)


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp-{uuid.uuid4().hex[:8]}")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


@contextmanager
def locked_json(path: Path, default_obj: dict[str, Any]):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    with os.fdopen(fd, "r+", encoding="utf-8") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        f.seek(0)
        raw = f.read().strip()
        if raw:
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                payload = deep_copy(default_obj)
        else:
            payload = deep_copy(default_obj)

        if not isinstance(payload, dict):
            payload = deep_copy(default_obj)

        yield payload

        f.seek(0)
        f.truncate()
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
        fcntl.flock(f.fileno(), fcntl.LOCK_UN)


def read_config(p: FsPaths) -> dict[str, Any]:
    cfg = read_json(p.config, {})
    if not isinstance(cfg, dict):
        raise SystemExit(f"invalid config: {p.config}")
    return cfg


def write_config(p: FsPaths, cfg: dict[str, Any]) -> None:
    cfg["updatedAt"] = now_ms()
    write_json(p.config, cfg)
    write_json(p.team_legacy, cfg)


def members(cfg: dict[str, Any]) -> list[dict[str, Any]]:
    val = cfg.get("members", [])
    if not isinstance(val, list):
        return []
    return [m for m in val if isinstance(m, dict)]


def member_index(cfg: dict[str, Any], ident: str) -> int:
    for idx, m in enumerate(members(cfg)):
        if str(m.get("name", "")) == ident or str(m.get("agentId", "")) == ident:
            return idx
    return -1


def inbox_path(p: FsPaths, agent: str) -> Path:
    return p.inboxes / f"{agent}.json"


def ensure_inbox(p: FsPaths, agent: str) -> None:
    ip = inbox_path(p, agent)
    if not ip.exists():
        write_json(ip, {"agent": agent, "messages": []})


def clear_runtime_artifacts(p: FsPaths) -> None:
    if p.inboxes.exists():
        for child in p.inboxes.iterdir():
            if child.is_file():
                try:
                    child.unlink()
                except OSError:
                    pass

    if p.tasks.exists():
        for child in p.tasks.iterdir():
            if child.is_dir():
                shutil.rmtree(child, ignore_errors=True)
            else:
                try:
                    child.unlink()
                except OSError:
                    pass

    logs_dir = p.root / "logs"
    if logs_dir.exists():
        for child in logs_dir.iterdir():
            if child.is_dir():
                shutil.rmtree(child, ignore_errors=True)
            else:
                try:
                    child.unlink()
                except OSError:
                    pass

    write_runtime(p, {"agents": {}})
    write_state(p, deep_copy(DEFAULT_STATE))
    write_control(p, {"requests": {}})


def read_mailbox(p: FsPaths, agent: str) -> list[dict[str, Any]]:
    ensure_inbox(p, agent)
    box = read_json(inbox_path(p, agent), {"agent": agent, "messages": []})
    msgs = box.get("messages", []) if isinstance(box, dict) else []
    out: list[dict[str, Any]] = []
    if isinstance(msgs, list):
        for m in msgs:
            if isinstance(m, dict):
                out.append(m)
    return out


def write_mailbox(p: FsPaths, agent: str, message: dict[str, Any]) -> int:
    ensure_inbox(p, agent)
    ip = inbox_path(p, agent)
    with locked_json(ip, {"agent": agent, "messages": []}) as box:
        msgs = box.setdefault("messages", [])
        if not isinstance(msgs, list):
            msgs = []
            box["messages"] = msgs
        msg = deep_copy(message)
        msg.setdefault("timestamp", utc_now_iso_ms())
        msg.setdefault("read", False)
        msgs.append(msg)
        return len(msgs) - 1


def unread_indexed(p: FsPaths, agent: str) -> list[tuple[int, dict[str, Any]]]:
    out: list[tuple[int, dict[str, Any]]] = []
    for idx, msg in enumerate(read_mailbox(p, agent)):
        if not bool(msg.get("read", False)):
            out.append((idx, msg))
    return out


def mark_read(p: FsPaths, agent: str, indexes: Iterable[int], mark_all: bool) -> int:
    ensure_inbox(p, agent)
    changed = 0
    wanted = set(indexes)
    ip = inbox_path(p, agent)
    with locked_json(ip, {"agent": agent, "messages": []}) as box:
        msgs = box.setdefault("messages", [])
        if not isinstance(msgs, list):
            return 0
        for idx, msg in enumerate(msgs):
            if not isinstance(msg, dict):
                continue
            if mark_all or idx in wanted:
                if not bool(msg.get("read", False)):
                    msg["read"] = True
                    changed += 1
    return changed


def read_state(p: FsPaths) -> dict[str, Any]:
    state = read_json(p.state, DEFAULT_STATE)
    if not isinstance(state, dict):
        state = deep_copy(DEFAULT_STATE)
    return state


def write_state(p: FsPaths, state: dict[str, Any]) -> None:
    write_json(p.state, state)


def read_runtime(p: FsPaths) -> dict[str, Any]:
    rt = read_json(p.runtime, {"agents": {}, "updatedAt": now_ms()})
    if not isinstance(rt, dict):
        rt = {"agents": {}, "updatedAt": now_ms()}
    if "agents" not in rt or not isinstance(rt["agents"], dict):
        rt["agents"] = {}
    return rt


def write_runtime(p: FsPaths, runtime: dict[str, Any]) -> None:
    runtime["updatedAt"] = now_ms()
    write_json(p.runtime, runtime)


def read_control(p: FsPaths) -> dict[str, Any]:
    ctl = read_json(p.control, {"requests": {}, "updatedAt": now_ms()})
    if not isinstance(ctl, dict):
        ctl = {"requests": {}, "updatedAt": now_ms()}
    reqs = ctl.get("requests", {})
    if not isinstance(reqs, dict):
        reqs = {}
    ctl["requests"] = reqs
    return ctl


def write_control(p: FsPaths, control: dict[str, Any]) -> None:
    control["updatedAt"] = now_ms()
    write_json(p.control, control)


def normalize_control_type(raw: str) -> str:
    val = str(raw or "").strip()
    if val.endswith("_request"):
        val = val[: -len("_request")]
    if val.endswith("_response"):
        val = val[: -len("_response")]
    if val not in {"plan_approval", "shutdown", "permission", "mode_set"}:
        raise SystemExit(f"unsupported control type: {raw}")
    return val


def make_request_id() -> str:
    return uuid.uuid4().hex[:12]


def create_control_request(
    p: FsPaths,
    cfg: dict[str, Any],
    *,
    req_type: str,
    sender: str,
    recipient: str,
    body: str,
    summary: str,
    request_id: str,
) -> str:
    req_type = normalize_control_type(req_type)
    rid = request_id.strip() or make_request_id()
    control = read_control(p)
    reqs = control.setdefault("requests", {})
    if not isinstance(reqs, dict):
        reqs = {}
        control["requests"] = reqs
    if rid in reqs:
        raise SystemExit(f"request already exists: {rid}")

    now = utc_now_iso_ms()
    req = {
        "request_id": rid,
        "req_type": req_type,
        "sender": sender,
        "recipient": recipient,
        "body": body,
        "summary": summary,
        "status": "pending",
        "created_ts": now,
        "updated_ts": now,
        "response_body": "",
        "responder": "",
    }
    reqs[rid] = req
    write_control(p, control)

    deliver_message(
        p,
        cfg,
        msg_type=f"{req_type}_request",
        sender=sender,
        recipient=recipient,
        content=body,
        summary=summary,
        request_id=rid,
        approve=None,
        meta={"request_id": rid, "req_type": req_type, "summary": summary, "state": "pending"},
    )
    return rid


def get_control_request(p: FsPaths, request_id: str) -> dict[str, Any] | None:
    control = read_control(p)
    reqs = control.get("requests", {})
    if not isinstance(reqs, dict):
        return None
    req = reqs.get(request_id)
    return req if isinstance(req, dict) else None


def resolve_control_response(
    p: FsPaths,
    cfg: dict[str, Any],
    *,
    request_id: str,
    responder: str,
    approve: bool,
    body: str,
    recipient_override: str,
    req_type_override: str,
) -> dict[str, Any]:
    control = read_control(p)
    reqs = control.setdefault("requests", {})
    if not isinstance(reqs, dict):
        reqs = {}
        control["requests"] = reqs

    req = reqs.get(request_id)
    if not isinstance(req, dict):
        if not req_type_override:
            raise SystemExit(f"request not found: {request_id}")
        req_type = normalize_control_type(req_type_override)
        req = {
            "request_id": request_id,
            "req_type": req_type,
            "sender": recipient_override or lead_name(cfg),
            "recipient": responder,
            "body": "",
            "summary": "",
            "status": "pending",
            "created_ts": utc_now_iso_ms(),
            "updated_ts": utc_now_iso_ms(),
            "response_body": "",
            "responder": "",
        }
        reqs[request_id] = req

    if str(req.get("status", "")) != "pending":
        raise SystemExit(f"request already resolved: {request_id} status={req.get('status', '')}")

    req_type = normalize_control_type(str(req.get("req_type", req_type_override)))
    status = "approved" if approve else "rejected"
    req["status"] = status
    req["updated_ts"] = utc_now_iso_ms()
    req["response_body"] = body
    req["responder"] = responder
    req["req_type"] = req_type
    reqs[request_id] = req
    write_control(p, control)

    recipient = recipient_override.strip() or str(req.get("sender", ""))
    if not recipient:
        recipient = lead_name(cfg)

    deliver_message(
        p,
        cfg,
        msg_type=f"{req_type}_response",
        sender=responder,
        recipient=recipient,
        content=body or status,
        summary=str(req.get("summary", "")),
        request_id=request_id,
        approve=approve,
        meta={"request_id": request_id, "req_type": req_type, "approve": approve, "state": status},
    )
    return req


def list_control_requests(
    p: FsPaths,
    *,
    recipient: str,
    include_resolved: bool,
    limit: int,
) -> list[dict[str, Any]]:
    control = read_control(p)
    reqs = control.get("requests", {})
    if not isinstance(reqs, dict):
        return []

    rows: list[dict[str, Any]] = []
    for req in reqs.values():
        if not isinstance(req, dict):
            continue
        if recipient and str(req.get("recipient", "")) != recipient:
            continue
        if not include_resolved and str(req.get("status", "")) != "pending":
            continue
        rows.append(req)
    rows.sort(key=lambda r: str(r.get("created_ts", "")))
    if limit > 0:
        rows = rows[:limit]
    return rows


def is_pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def runtime_prune(runtime: dict[str, Any]) -> int:
    changed = 0
    agents = runtime.get("agents", {})
    if not isinstance(agents, dict):
        runtime["agents"] = {}
        return 0
    for name, rec in list(agents.items()):
        if not isinstance(rec, dict):
            continue
        pid = int(rec.get("pid", 0) or 0)
        status = str(rec.get("status", ""))
        if status == "running" and pid > 0 and not is_pid_alive(pid):
            rec["status"] = "terminated"
            rec["updatedAt"] = now_ms()
            changed += 1
        agents[name] = rec
    runtime["agents"] = agents
    return changed


def active_agents(runtime: dict[str, Any]) -> list[str]:
    out: list[str] = []
    agents = runtime.get("agents", {})
    if not isinstance(agents, dict):
        return out
    for name, rec in agents.items():
        if not isinstance(rec, dict):
            continue
        if str(rec.get("status", "")) != "running":
            continue
        pid = int(rec.get("pid", 0) or 0)
        if pid > 0 and is_pid_alive(pid):
            out.append(str(name))
    return out


def lead_name(cfg: dict[str, Any]) -> str:
    lead_id = str(cfg.get("leadAgentId", ""))
    for m in members(cfg):
        if str(m.get("agentId", "")) == lead_id and m.get("name"):
            return str(m.get("name"))
    if members(cfg):
        return str(members(cfg)[0].get("name", "team-lead"))
    return "team-lead"


def member_color(cfg: dict[str, Any], name: str) -> str:
    idx = member_index(cfg, name)
    if idx < 0:
        return "blue"
    return str(members(cfg)[idx].get("color", "blue"))


def build_teammates(cfg: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for m in members(cfg):
        aid = str(m.get("agentId", ""))
        if not aid:
            continue
        out[aid] = {
            "name": m.get("name", ""),
            "agentType": m.get("agentType", "member"),
            "color": m.get("color", "blue"),
            "backendType": m.get("backendType", "tmux"),
            "mode": m.get("mode", "auto"),
            "planModeRequired": bool(m.get("planModeRequired", False)),
        }
    return out


def set_state_team_context(p: FsPaths, cfg: dict[str, Any], self_name: str) -> None:
    state = read_state(p)
    team_name = str(cfg.get("name", "team"))
    state["teamContext"] = {
        "teamName": team_name,
        "teamFilePath": str(p.config),
        "teamConfigPath": str(p.config),
        "taskListPath": str(p.tasks),
        "leadAgentId": cfg.get("leadAgentId", ""),
        "leadAgentName": lead_name(cfg),
        "selfAgentId": make_agent_id(self_name, team_name),
        "selfAgentName": self_name,
        "selfAgentColor": member_color(cfg, self_name),
        "teammates": build_teammates(cfg),
    }
    if "inbox" not in state or not isinstance(state["inbox"], dict):
        state["inbox"] = {"messages": []}
    if "messages" not in state["inbox"] or not isinstance(state["inbox"]["messages"], list):
        state["inbox"]["messages"] = []
    write_state(p, state)


def clear_state_team_context(p: FsPaths) -> None:
    state = read_state(p)
    state["teamContext"] = None
    write_state(p, state)


def create_team_config(
    team_name: str,
    description: str,
    lead_name_value: str,
    lead_agent_type: str,
    lead_model: str,
    lead_cwd: str,
    lead_session_id: str,
    parent_session_id: str,
    lead_backend_type: str,
    lead_mode: str,
) -> dict[str, Any]:
    ts = now_ms()
    safe_team = sanitize_team_name(team_name)
    lead_id = make_agent_id(lead_name_value, safe_team)
    return {
        "name": safe_team,
        "description": description,
        "createdAt": ts,
        "updatedAt": ts,
        "leadAgentId": lead_id,
        "leadSessionId": lead_session_id,
        "parentSessionId": parent_session_id,
        "members": [
            {
                "agentId": lead_id,
                "name": lead_name_value,
                "agentType": lead_agent_type,
                "model": lead_model,
                "prompt": "",
                "color": assign_color(0),
                "planModeRequired": False,
                "joinedAt": ts,
                "tmuxPaneId": "",
                "cwd": lead_cwd,
                "subscriptions": [],
                "backendType": lead_backend_type,
                "mode": lead_mode,
            }
        ],
        "hiddenPaneIds": [],
    }


def add_member(
    cfg: dict[str, Any],
    *,
    name: str,
    agent_type: str,
    model: str,
    prompt: str,
    color: str,
    plan_mode_required: bool,
    cwd: str,
    backend_type: str,
    mode: str,
    pane_id: str,
) -> dict[str, Any]:
    if member_index(cfg, name) >= 0:
        raise SystemExit(f"member already exists: {name}")
    team_name = str(cfg.get("name", "team"))
    idx = len(members(cfg))
    rec = {
        "agentId": make_agent_id(name, team_name),
        "name": name,
        "agentType": agent_type,
        "model": model,
        "prompt": prompt,
        "color": color or assign_color(idx),
        "planModeRequired": bool(plan_mode_required),
        "joinedAt": now_ms(),
        "tmuxPaneId": pane_id,
        "cwd": cwd,
        "subscriptions": [],
        "backendType": backend_type,
        "mode": mode,
    }
    new_members = members(cfg)
    new_members.append(rec)
    cfg["members"] = new_members
    return rec


def remove_member(cfg: dict[str, Any], ident: str) -> bool:
    lead_id = str(cfg.get("leadAgentId", ""))
    changed = False
    keep: list[dict[str, Any]] = []
    for m in members(cfg):
        if str(m.get("name", "")) == ident or str(m.get("agentId", "")) == ident:
            if str(m.get("agentId", "")) == lead_id:
                raise SystemExit("cannot remove team lead")
            changed = True
            continue
        keep.append(m)
    cfg["members"] = keep
    return changed


def set_member_mode(cfg: dict[str, Any], ident: str, mode: str) -> bool:
    idx = member_index(cfg, ident)
    if idx < 0:
        return False
    new_members = members(cfg)
    new_members[idx]["mode"] = mode
    cfg["members"] = new_members
    return True


def deliver_message(
    p: FsPaths,
    cfg: dict[str, Any],
    *,
    msg_type: str,
    sender: str,
    recipient: str,
    content: str,
    summary: str,
    request_id: str,
    approve: bool | None,
    meta: dict[str, Any],
) -> list[str]:
    if msg_type not in MESSAGE_TYPES:
        raise SystemExit(f"unsupported message type: {msg_type}")

    all_names = [str(m.get("name", "")) for m in members(cfg) if m.get("name")]
    targets: list[str]
    if msg_type == "broadcast":
        targets = [n for n in all_names if n != sender]
    else:
        if not recipient:
            raise SystemExit("recipient required for non-broadcast message")
        targets = [recipient]

    body = {
        "type": msg_type,
        "from": sender,
        "text": content,
        "summary": summary,
        "timestamp": utc_now_iso_ms(),
        "color": member_color(cfg, sender),
        "read": False,
    }
    if request_id:
        body["request_id"] = request_id
    if approve is not None:
        body["approve"] = bool(approve)
    if meta:
        body["meta"] = meta

    delivered: list[str] = []
    for target in targets:
        payload = deep_copy(body)
        payload["recipient"] = target
        write_mailbox(p, target, payload)
        delivered.append(target)
    return delivered


def cmd_team_create(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    ensure_dirs(p)
    if p.config.exists() and not args.replace:
        cfg = read_json(p.config, {})
        raise SystemExit(f'Already leading team "{cfg.get("name", "unknown")}"')
    if args.replace:
        clear_runtime_artifacts(p)

    cfg = create_team_config(
        team_name=args.team_name,
        description=args.description,
        lead_name_value=args.lead_name,
        lead_agent_type=args.agent_type,
        lead_model=args.model,
        lead_cwd=str(Path(args.cwd).resolve()),
        lead_session_id=args.lead_session_id or str(uuid.uuid4()),
        parent_session_id=args.parent_session_id or str(uuid.uuid4()),
        lead_backend_type=args.backend_type,
        lead_mode=args.mode,
    )
    write_config(p, cfg)
    write_control(p, {"requests": {}, "updatedAt": now_ms()})
    ensure_inbox(p, args.lead_name)
    set_state_team_context(p, cfg, args.lead_name)
    out = {
        "team_name": cfg["name"],
        "team_root": str(p.root),
        "config": str(p.config),
        "tasks": str(p.tasks),
        "lead": args.lead_name,
    }
    if args.json:
        print(json.dumps(out, ensure_ascii=False))
    else:
        for k in ("team_name", "team_root", "config", "tasks", "lead"):
            print(f"{k}={out[k]}")
    return 0


def cmd_team_delete(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    if not p.root.exists():
        print(f"deleted={p.root}")
        return 0
    runtime = read_runtime(p)
    runtime_prune(runtime)
    running = active_agents(runtime)
    if running and not args.force:
        raise SystemExit(f"active members exist: {', '.join(running)}")
    shutil.rmtree(p.root, ignore_errors=True)
    print(f"deleted={p.root}")
    return 0


def cmd_team_get(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    if args.json:
        print(json.dumps(cfg, ensure_ascii=False))
    else:
        print(json.dumps(cfg, ensure_ascii=False, indent=2))
    return 0


def cmd_member_add(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    rec = add_member(
        cfg,
        name=args.name,
        agent_type=args.agent_type,
        model=args.model,
        prompt=args.prompt,
        color=args.color,
        plan_mode_required=args.plan_mode_required,
        cwd=str(Path(args.cwd).resolve()),
        backend_type=args.backend_type,
        mode=args.mode,
        pane_id=args.tmux_pane_id,
    )
    write_config(p, cfg)
    ensure_inbox(p, args.name)
    if args.json:
        print(json.dumps(rec, ensure_ascii=False))
    else:
        print(f"added={rec['name']}")
        print(f"agent_id={rec['agentId']}")
        print(f"color={rec['color']}")
    return 0


def cmd_member_remove(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    changed = remove_member(cfg, args.ident)
    if changed:
        write_config(p, cfg)
    print(f"removed={str(changed).lower()}")
    return 0


def cmd_member_mode(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    changed = set_member_mode(cfg, args.ident, args.mode)
    if changed:
        write_config(p, cfg)
    print(f"updated={str(changed).lower()}")
    return 0


def cmd_member_batch_mode(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    changed = 0
    for entry in args.entry:
        if ":" not in entry:
            raise SystemExit(f"invalid --entry format: {entry}")
        ident, mode = entry.split(":", 1)
        if set_member_mode(cfg, ident.strip(), mode.strip()):
            changed += 1
    if changed:
        write_config(p, cfg)
    print(f"updated={changed}")
    return 0


def cmd_control_request(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    rid = create_control_request(
        p,
        cfg,
        req_type=args.req_type,
        sender=args.sender,
        recipient=args.recipient,
        body=args.body,
        summary=args.summary,
        request_id=args.request_id,
    )
    print(f"request_id={rid}")
    return 0


def cmd_control_respond(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    approve = bool(args.approve and not args.reject)
    req = resolve_control_response(
        p,
        cfg,
        request_id=args.request_id,
        responder=args.sender,
        approve=approve,
        body=args.body or ("approved" if approve else "rejected"),
        recipient_override=args.recipient,
        req_type_override=args.req_type,
    )
    print(f"request_id={req.get('request_id', '')}")
    print(f"status={req.get('status', '')}")
    print(f"req_type={req.get('req_type', '')}")
    print(f"sender={req.get('sender', '')}")
    print(f"recipient={req.get('recipient', '')}")
    return 0


def cmd_control_pending(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    rows = list_control_requests(
        p,
        recipient=args.agent,
        include_resolved=args.all_status,
        limit=args.limit,
    )
    if args.json:
        print(json.dumps(rows, ensure_ascii=False))
        return 0

    if not rows:
        print("(no requests)")
        return 0

    for r in rows:
        print(
            f"request_id={r.get('request_id', '')} type={r.get('req_type', '')} "
            f"from={r.get('sender', '')} to={r.get('recipient', '')} status={r.get('status', '')} "
            f"created={r.get('created_ts', '')}"
        )
        print(f"body={r.get('body', '')}")
        if r.get("response_body"):
            print(f"response={r.get('response_body', '')}")
    return 0


def cmd_control_get(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    req = get_control_request(p, args.request_id)
    if not req:
        raise SystemExit(f"request not found: {args.request_id}")
    if args.json:
        print(json.dumps(req, ensure_ascii=False))
    else:
        for k in ("request_id", "req_type", "sender", "recipient", "status", "created_ts", "updated_ts"):
            print(f"{k}={req.get(k, '')}")
        print(f"body={req.get('body', '')}")
        print(f"response_body={req.get('response_body', '')}")
    return 0


def cmd_mailbox_write(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    ensure_dirs(p)
    msg = {
        "type": args.msg_type,
        "from": args.sender,
        "text": args.text,
        "summary": args.summary,
        "timestamp": utc_now_iso_ms(),
        "color": args.color,
        "read": False,
    }
    if args.request_id:
        msg["request_id"] = args.request_id
    if args.approve is not None:
        msg["approve"] = args.approve
    meta = parse_json_object(args.meta)
    if meta:
        msg["meta"] = meta
    idx = write_mailbox(p, args.agent, msg)
    print(f"mailbox_index={idx}")
    return 0


def cmd_mailbox_read(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    values = unread_indexed(p, args.agent) if args.unread else list(enumerate(read_mailbox(p, args.agent)))
    if args.limit > 0:
        values = values[-args.limit :]
    if args.json:
        print(json.dumps([{"index": idx, **msg} for idx, msg in values], ensure_ascii=False))
    else:
        for idx, msg in values:
            print(
                f"[{idx:04d}] read={str(bool(msg.get('read', False))).lower()} "
                f"type={msg.get('type', '')} from={msg.get('from', '')} "
                f"summary={msg.get('summary', '')} text={msg.get('text', '')}"
            )
    return 0


def cmd_mailbox_mark_read(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    changed = mark_read(p, args.agent, indexes=args.index, mark_all=args.all)
    print(f"marked={changed}")
    return 0


def cmd_mailbox_format(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    values = unread_indexed(p, args.agent) if args.unread else list(enumerate(read_mailbox(p, args.agent)))
    if args.limit > 0:
        values = values[-args.limit :]
    lines = []
    for _, msg in values:
        lines.append(
            f'<teammate-message teammate_id="{msg.get("from", "")}" '
            f'color="{msg.get("color", "")}" summary="{msg.get("summary", "")}">'
            f'{msg.get("text", "")}</teammate-message>'
        )
    print("\n".join(lines))
    return 0


def cmd_dispatch(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    delivered = deliver_message(
        p,
        cfg,
        msg_type=args.msg_type,
        sender=args.sender,
        recipient=args.recipient,
        content=args.content,
        summary=args.summary,
        request_id=args.request_id,
        approve=args.approve,
        meta=parse_json_object(args.meta),
    )
    print(json.dumps({"delivered": delivered}, ensure_ascii=False))
    return 0


def cmd_send_to_lead(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    target = lead_name(cfg)
    msg = {
        "type": "message",
        "from": args.sender,
        "text": args.text,
        "summary": args.summary,
        "timestamp": utc_now_iso_ms(),
        "color": args.color,
        "read": False,
    }
    write_mailbox(p, target, msg)
    print(json.dumps({"delivered": [target]}, ensure_ascii=False))
    return 0


def cmd_send_idle(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    target = lead_name(cfg)
    msg = {
        "type": "idle_notification",
        "from": args.agent,
        "text": f"idle notification from {args.agent}",
        "summary": "idle",
        "timestamp": utc_now_iso_ms(),
        "color": member_color(cfg, args.agent),
        "read": False,
    }
    write_mailbox(p, target, msg)
    print(json.dumps({"delivered": [target]}, ensure_ascii=False))
    return 0


def cmd_inbox_poll(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    indexed = unread_indexed(p, args.agent)
    if args.limit > 0:
        indexed = indexed[: args.limit]
    state = read_state(p)
    inbox_state = state.setdefault("inbox", {})
    queue = inbox_state.setdefault("messages", [])
    if not isinstance(queue, list):
        queue = []
        inbox_state["messages"] = queue
    perm_state = state.setdefault("workerSandboxPermissions", {"queue": [], "selectedIndex": 0})
    if not isinstance(perm_state, dict):
        perm_state = {"queue": [], "selectedIndex": 0}
        state["workerSandboxPermissions"] = perm_state
    perm_queue = perm_state.setdefault("queue", [])
    if not isinstance(perm_queue, list):
        perm_queue = []
        perm_state["queue"] = perm_queue
    payload: list[dict[str, Any]] = []
    for idx, msg in indexed:
        item = {"mailbox_index": idx, "agent": args.agent, "message": msg}
        queue.append(item)
        payload.append(item)
        if str(msg.get("type", "")) == "permission_request":
            perm_queue.append(
                {
                    "mailbox_index": idx,
                    "request_id": msg.get("request_id", ""),
                    "from": msg.get("from", ""),
                    "summary": msg.get("summary", ""),
                    "text": msg.get("text", ""),
                    "timestamp": msg.get("timestamp", ""),
                    "color": msg.get("color", "blue"),
                    "recipient": msg.get("recipient", ""),
                }
            )
    if args.mark_read and indexed:
        mark_read(p, args.agent, indexes=[idx for idx, _ in indexed], mark_all=False)
    write_state(p, state)
    if args.json:
        print(json.dumps(payload, ensure_ascii=False))
    else:
        for item in payload:
            msg = item["message"]
            print(
                f"queued mailbox_index={item['mailbox_index']} type={msg.get('type', '')} "
                f"from={msg.get('from', '')} summary={msg.get('summary', '')}"
            )
    return 0


def cmd_state_context_set(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    cfg = read_config(p)
    set_state_team_context(p, cfg, args.self_name)
    print(f"state={p.state}")
    return 0


def cmd_state_context_clear(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    clear_state_team_context(p)
    print(f"state={p.state}")
    return 0


def cmd_state_get(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    state = read_state(p)
    print(json.dumps(state, ensure_ascii=False, indent=None if args.compact else 2))
    return 0


def cmd_runtime_set(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    rt = read_runtime(p)
    agents = rt.setdefault("agents", {})
    rec = agents.get(args.agent, {}) if isinstance(agents.get(args.agent), dict) else {}
    rec["agent"] = args.agent
    rec["backend"] = args.backend
    rec["status"] = args.status
    rec["pid"] = args.pid
    rec["paneId"] = args.pane_id
    rec["window"] = args.window
    rec["updatedAt"] = now_ms()
    rec.setdefault("startedAt", now_ms())
    agents[args.agent] = rec
    rt["agents"] = agents
    write_runtime(p, rt)
    print(json.dumps(rec, ensure_ascii=False))
    return 0


def cmd_runtime_mark(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    rt = read_runtime(p)
    agents = rt.setdefault("agents", {})
    rec = agents.get(args.agent)
    if not isinstance(rec, dict):
        raise SystemExit(f"runtime agent not found: {args.agent}")
    rec["status"] = args.status
    if args.pid is not None:
        rec["pid"] = args.pid
    rec["updatedAt"] = now_ms()
    agents[args.agent] = rec
    rt["agents"] = agents
    write_runtime(p, rt)
    print(json.dumps(rec, ensure_ascii=False))
    return 0


def cmd_runtime_list(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    rt = read_runtime(p)
    changed = runtime_prune(rt)
    if changed and args.prune_write:
        write_runtime(p, rt)
    if args.json:
        print(json.dumps(rt, ensure_ascii=False))
    else:
        agents = rt.get("agents", {})
        if not isinstance(agents, dict):
            agents = {}
        for name in sorted(agents.keys()):
            rec = agents[name]
            if not isinstance(rec, dict):
                continue
            print(
                f"agent={name} backend={rec.get('backend', '')} status={rec.get('status', '')} "
                f"pid={rec.get('pid', 0)} pane={rec.get('paneId', '')} window={rec.get('window', '')}"
            )
    return 0


def cmd_runtime_kill(args: argparse.Namespace) -> int:
    p = resolve_paths(args.repo, args.session)
    rt = read_runtime(p)
    agents = rt.get("agents", {})
    if not isinstance(agents, dict):
        raise SystemExit("runtime has no agents map")
    rec = agents.get(args.agent)
    if not isinstance(rec, dict):
        raise SystemExit(f"runtime agent not found: {args.agent}")
    pid = int(rec.get("pid", 0) or 0)
    if pid > 0 and is_pid_alive(pid):
        sig = signal.SIGTERM if args.signal == "term" else signal.SIGKILL
        os.kill(pid, sig)
    rec["status"] = "terminated"
    rec["updatedAt"] = now_ms()
    agents[args.agent] = rec
    rt["agents"] = agents
    write_runtime(p, rt)
    print(json.dumps(rec, ensure_ascii=False))
    return 0


def cmd_color_map(args: argparse.Namespace) -> int:
    print(color_to_tmux_border(args.color))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="codex-teams filesystem core")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("team-create")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--team-name", required=True)
    p.add_argument("--description", default="")
    p.add_argument("--agent-type", default="team-lead")
    p.add_argument("--lead-name", default="team-lead")
    p.add_argument("--model", default="")
    p.add_argument("--cwd", default=os.getcwd())
    p.add_argument("--lead-session-id", default="")
    p.add_argument("--parent-session-id", default="")
    p.add_argument("--backend-type", default="tmux")
    p.add_argument("--mode", default="auto")
    p.add_argument("--replace", action="store_true")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_team_create)

    p = sub.add_parser("team-delete")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_team_delete)

    p = sub.add_parser("team-get")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_team_get)

    p = sub.add_parser("member-add")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--agent-type", default="worker")
    p.add_argument("--model", default="")
    p.add_argument("--prompt", default="")
    p.add_argument("--color", default="")
    p.add_argument("--plan-mode-required", action="store_true")
    p.add_argument("--cwd", default=os.getcwd())
    p.add_argument("--backend-type", default="tmux")
    p.add_argument("--mode", default="auto")
    p.add_argument("--tmux-pane-id", default="")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_member_add)

    p = sub.add_parser("member-remove")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--ident", required=True)
    p.set_defaults(func=cmd_member_remove)

    p = sub.add_parser("member-mode")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--ident", required=True)
    p.add_argument("--mode", required=True)
    p.set_defaults(func=cmd_member_mode)

    p = sub.add_parser("member-batch-mode")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--entry", action="append", required=True, help="name:mode")
    p.set_defaults(func=cmd_member_batch_mode)

    p = sub.add_parser("control-request")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--type", dest="req_type", required=True, choices=["plan_approval", "shutdown", "permission", "mode_set"])
    p.add_argument("--from", dest="sender", required=True)
    p.add_argument("--to", dest="recipient", required=True)
    p.add_argument("--body", required=True)
    p.add_argument("--summary", default="")
    p.add_argument("--request-id", default="")
    p.set_defaults(func=cmd_control_request)

    p = sub.add_parser("control-respond")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--request-id", required=True)
    p.add_argument("--from", dest="sender", required=True)
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--approve", action="store_true")
    group.add_argument("--reject", action="store_true")
    p.add_argument("--body", default="")
    p.add_argument("--to", dest="recipient", default="")
    p.add_argument("--req-type", default="")
    p.set_defaults(func=cmd_control_respond)

    p = sub.add_parser("control-pending")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--agent", required=True)
    p.add_argument("--all-status", action="store_true")
    p.add_argument("--limit", type=int, default=100)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_control_pending)

    p = sub.add_parser("control-get")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--request-id", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_control_get)

    p = sub.add_parser("mailbox-write")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--agent", required=True)
    p.add_argument("--from", dest="sender", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--summary", default="")
    p.add_argument("--color", default="blue")
    p.add_argument("--type", dest="msg_type", required=True)
    p.add_argument("--request-id", default="")
    p.add_argument("--approve", type=lambda x: x.lower() in {"1", "true", "yes"}, default=None)
    p.add_argument("--meta", default="{}")
    p.set_defaults(func=cmd_mailbox_write)

    p = sub.add_parser("mailbox-read")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--agent", required=True)
    p.add_argument("--unread", action="store_true")
    p.add_argument("--limit", type=int, default=100)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_mailbox_read)

    p = sub.add_parser("mailbox-mark-read")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--agent", required=True)
    p.add_argument("--index", action="append", type=int, default=[])
    p.add_argument("--all", action="store_true")
    p.set_defaults(func=cmd_mailbox_mark_read)

    p = sub.add_parser("mailbox-format")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--agent", required=True)
    p.add_argument("--unread", action="store_true")
    p.add_argument("--limit", type=int, default=100)
    p.set_defaults(func=cmd_mailbox_format)

    p = sub.add_parser("dispatch")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--type", dest="msg_type", required=True)
    p.add_argument("--from", dest="sender", required=True)
    p.add_argument("--recipient", default="")
    p.add_argument("--content", required=True)
    p.add_argument("--summary", default="")
    p.add_argument("--request-id", default="")
    p.add_argument("--approve", type=lambda x: x.lower() in {"1", "true", "yes"}, default=None)
    p.add_argument("--meta", default="{}")
    p.set_defaults(func=cmd_dispatch)

    p = sub.add_parser("send-to-lead")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--from", dest="sender", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--summary", default="")
    p.add_argument("--color", default="blue")
    p.set_defaults(func=cmd_send_to_lead)

    p = sub.add_parser("send-idle")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--agent", required=True)
    p.set_defaults(func=cmd_send_idle)

    p = sub.add_parser("inbox-poll")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--agent", required=True)
    p.add_argument("--limit", type=int, default=100)
    p.add_argument("--mark-read", action="store_true")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_inbox_poll)

    p = sub.add_parser("state-context-set")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--self-name", default="team-lead")
    p.set_defaults(func=cmd_state_context_set)

    p = sub.add_parser("state-context-clear")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.set_defaults(func=cmd_state_context_clear)

    p = sub.add_parser("state-get")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--compact", action="store_true")
    p.set_defaults(func=cmd_state_get)

    p = sub.add_parser("runtime-set")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--agent", required=True)
    p.add_argument("--backend", default="tmux")
    p.add_argument("--status", default="running")
    p.add_argument("--pid", type=int, default=0)
    p.add_argument("--pane-id", default="")
    p.add_argument("--window", default="")
    p.set_defaults(func=cmd_runtime_set)

    p = sub.add_parser("runtime-mark")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--agent", required=True)
    p.add_argument("--status", required=True)
    p.add_argument("--pid", type=int, default=None)
    p.set_defaults(func=cmd_runtime_mark)

    p = sub.add_parser("runtime-list")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--json", action="store_true")
    p.add_argument("--prune-write", action="store_true")
    p.set_defaults(func=cmd_runtime_list)

    p = sub.add_parser("runtime-kill")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--session", required=True)
    p.add_argument("--agent", required=True)
    p.add_argument("--signal", choices=["term", "kill"], default="term")
    p.set_defaults(func=cmd_runtime_kill)

    p = sub.add_parser("color-map")
    p.add_argument("--color", required=True)
    p.set_defaults(func=cmd_color_map)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
