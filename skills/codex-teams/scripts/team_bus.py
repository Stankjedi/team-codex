#!/usr/bin/env python3
"""Local real-time message bus for Codex team sessions.

This module provides three layers:
1) message log (`messages`)
2) per-recipient mailbox state (`mailbox`, unread/read)
3) control request lifecycle (`control_requests`)
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, Sequence


DEFAULT_DB = ".codex-teams/bus.sqlite"
DEFAULT_ROOM = "main"
CONTROL_TYPES = ("plan_approval", "shutdown", "permission", "mode_set")


@dataclass
class Message:
    id: int
    ts: str
    room: str
    sender: str
    recipient: str
    kind: str
    body: str
    meta_json: str


@dataclass
class MailItem:
    mailbox_id: int
    state: str
    created_ts: str
    read_ts: str | None
    message_id: int
    ts: str
    kind: str
    sender: str
    recipient: str
    body: str
    meta_json: str


@dataclass
class ControlRequest:
    request_id: str
    room: str
    req_type: str
    sender: str
    recipient: str
    body: str
    status: str
    created_ts: str
    updated_ts: str
    response_body: str


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def connect(db_path: str) -> sqlite3.Connection:
    parent = os.path.dirname(db_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    return conn


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            room TEXT NOT NULL,
            sender TEXT NOT NULL,
            recipient TEXT NOT NULL,
            kind TEXT NOT NULL,
            body TEXT NOT NULL,
            meta_json TEXT NOT NULL DEFAULT '{}'
        );
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS members (
            room TEXT NOT NULL,
            agent TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'member',
            status TEXT NOT NULL DEFAULT 'active',
            joined_ts TEXT NOT NULL,
            last_seen_ts TEXT NOT NULL,
            PRIMARY KEY (room, agent)
        );
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS mailbox (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id INTEGER NOT NULL,
            room TEXT NOT NULL,
            recipient TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'unread',
            created_ts TEXT NOT NULL,
            read_ts TEXT,
            FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
        );
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS control_requests (
            request_id TEXT PRIMARY KEY,
            room TEXT NOT NULL,
            req_type TEXT NOT NULL,
            sender TEXT NOT NULL,
            recipient TEXT NOT NULL,
            body TEXT NOT NULL,
            status TEXT NOT NULL,
            created_ts TEXT NOT NULL,
            updated_ts TEXT NOT NULL,
            response_body TEXT NOT NULL DEFAULT ''
        );
        """
    )

    conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_room_id ON messages(room, id);")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_recipient ON messages(recipient, id);")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_members_room_role ON members(room, role, status);")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_mailbox_room_recipient_state ON mailbox(room, recipient, state, id);")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_control_requests_room_recipient_status ON control_requests(room, recipient, status, created_ts);"
    )
    conn.commit()


def parse_meta(raw: str | None) -> str:
    if not raw:
        return "{}"
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid --meta JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise SystemExit("--meta must decode to a JSON object")
    return json.dumps(parsed, ensure_ascii=True, separators=(",", ":"))


def touch_member(conn: sqlite3.Connection, *, room: str, agent: str, role: str = "member", status: str = "active") -> None:
    now = utc_now_iso()
    conn.execute(
        """
        INSERT INTO members(room, agent, role, status, joined_ts, last_seen_ts)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(room, agent)
        DO UPDATE SET
            role=CASE WHEN excluded.role='member' THEN members.role ELSE excluded.role END,
            status=CASE WHEN excluded.status='active' THEN members.status ELSE excluded.status END,
            last_seen_ts=excluded.last_seen_ts
        """,
        (room, agent, role, status, now, now),
    )


def resolve_recipients(conn: sqlite3.Connection, *, room: str, sender: str, recipient: str) -> list[str]:
    if recipient != "all":
        return [recipient]

    rows = conn.execute(
        """
        SELECT agent
        FROM members
        WHERE room=? AND status='active' AND agent<>?
        ORDER BY agent ASC
        """,
        (room, sender),
    ).fetchall()
    return [str(r["agent"]) for r in rows]


def insert_message(
    conn: sqlite3.Connection,
    *,
    room: str,
    sender: str,
    recipient: str,
    kind: str,
    body: str,
    meta_json: str,
) -> int:
    cur = conn.execute(
        """
        INSERT INTO messages (ts, room, sender, recipient, kind, body, meta_json)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (utc_now_iso(), room, sender, recipient, kind, body, meta_json),
    )
    return int(cur.lastrowid)


def add_mailbox_entries(conn: sqlite3.Connection, *, room: str, message_id: int, recipients: Sequence[str]) -> int:
    if not recipients:
        return 0

    now = utc_now_iso()
    for rcpt in recipients:
        conn.execute(
            """
            INSERT INTO mailbox(message_id, room, recipient, state, created_ts, read_ts)
            VALUES (?, ?, ?, 'unread', ?, NULL)
            """,
            (message_id, room, rcpt, now),
        )
    return len(recipients)


def send_message(
    conn: sqlite3.Connection,
    *,
    room: str,
    sender: str,
    recipient: str,
    kind: str,
    body: str,
    meta_json: str,
) -> tuple[int, int]:
    touch_member(conn, room=room, agent=sender)
    if recipient != "all":
        touch_member(conn, room=room, agent=recipient)

    msg_id = insert_message(
        conn,
        room=room,
        sender=sender,
        recipient=recipient,
        kind=kind,
        body=body,
        meta_json=meta_json,
    )

    recipients = resolve_recipients(conn, room=room, sender=sender, recipient=recipient)
    fanout_count = add_mailbox_entries(conn, room=room, message_id=msg_id, recipients=recipients)
    conn.commit()
    return msg_id, fanout_count


def fetch_messages(
    conn: sqlite3.Connection,
    *,
    room: str,
    since_id: int,
    agent: str,
    include_all: bool,
    limit: int,
) -> list[Message]:
    params: list[object] = [room, since_id]
    visibility_sql = ""
    if not include_all:
        visibility_sql = " AND (recipient='all' OR recipient=? OR sender=?)"
        params.extend([agent, agent])

    params.append(limit)

    rows = conn.execute(
        f"""
        SELECT id, ts, room, sender, recipient, kind, body, meta_json
        FROM messages
        WHERE room=? AND id>? {visibility_sql}
        ORDER BY id ASC
        LIMIT ?
        """,
        params,
    ).fetchall()

    return [Message(**dict(row)) for row in rows]


def fetch_inbox(
    conn: sqlite3.Connection,
    *,
    room: str,
    agent: str,
    unread_only: bool,
    since_mailbox_id: int,
    limit: int,
) -> list[MailItem]:
    params: list[object] = [room, agent, since_mailbox_id]
    where = ""
    if unread_only:
        where = " AND mb.state='unread'"

    params.append(limit)
    rows = conn.execute(
        f"""
        SELECT
            mb.id AS mailbox_id,
            mb.state,
            mb.created_ts,
            mb.read_ts,
            m.id AS message_id,
            m.ts,
            m.kind,
            m.sender,
            m.recipient,
            m.body,
            m.meta_json
        FROM mailbox mb
        JOIN messages m ON m.id=mb.message_id
        WHERE mb.room=? AND mb.recipient=? AND mb.id>? {where}
        ORDER BY mb.id ASC
        LIMIT ?
        """,
        params,
    ).fetchall()
    return [MailItem(**dict(r)) for r in rows]


def mark_read(
    conn: sqlite3.Connection,
    *,
    room: str,
    agent: str,
    mailbox_ids: Sequence[int] | None,
    up_to: int | None,
    mark_all: bool,
) -> int:
    now = utc_now_iso()
    if mailbox_ids:
        placeholders = ",".join("?" for _ in mailbox_ids)
        params: list[object] = [room, agent, now, *mailbox_ids]
        cur = conn.execute(
            f"""
            UPDATE mailbox
            SET state='read', read_ts=?
            WHERE room=? AND recipient=? AND state='unread' AND id IN ({placeholders})
            """,
            [now, room, agent, *mailbox_ids],
        )
    elif up_to is not None:
        cur = conn.execute(
            """
            UPDATE mailbox
            SET state='read', read_ts=?
            WHERE room=? AND recipient=? AND state='unread' AND id<=?
            """,
            (now, room, agent, up_to),
        )
    elif mark_all:
        cur = conn.execute(
            """
            UPDATE mailbox
            SET state='read', read_ts=?
            WHERE room=? AND recipient=? AND state='unread'
            """,
            (now, room, agent),
        )
    else:
        return 0

    conn.commit()
    return int(cur.rowcount)


def create_control_request(
    conn: sqlite3.Connection,
    *,
    room: str,
    req_type: str,
    sender: str,
    recipient: str,
    body: str,
    summary: str,
    request_id: str,
) -> str:
    request_id = request_id.strip() or uuid.uuid4().hex[:12]
    exists = conn.execute(
        "SELECT 1 FROM control_requests WHERE request_id=?",
        (request_id,),
    ).fetchone()
    if exists is not None:
        raise SystemExit(f"request already exists: {request_id}")
    now = utc_now_iso()
    conn.execute(
        """
        INSERT INTO control_requests(request_id, room, req_type, sender, recipient, body, status, created_ts, updated_ts, response_body)
        VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, '')
        """,
        (request_id, room, req_type, sender, recipient, body, now, now),
    )

    meta = parse_meta(
        json.dumps(
            {
                "request_id": request_id,
                "req_type": req_type,
                "summary": summary,
                "state": "pending",
            },
            ensure_ascii=True,
        )
    )
    send_message(
        conn,
        room=room,
        sender=sender,
        recipient=recipient,
        kind=f"{req_type}_request",
        body=body,
        meta_json=meta,
    )
    return request_id


def get_control_request(conn: sqlite3.Connection, *, request_id: str) -> ControlRequest | None:
    row = conn.execute(
        """
        SELECT request_id, room, req_type, sender, recipient, body, status, created_ts, updated_ts, response_body
        FROM control_requests
        WHERE request_id=?
        """,
        (request_id,),
    ).fetchone()
    if row is None:
        return None
    return ControlRequest(**dict(row))


def respond_control_request(
    conn: sqlite3.Connection,
    *,
    request_id: str,
    responder: str,
    approve: bool,
    response_body: str,
) -> ControlRequest:
    req = get_control_request(conn, request_id=request_id)
    if req is None:
        raise SystemExit(f"request not found: {request_id}")
    if req.status != "pending":
        raise SystemExit(f"request already resolved: {request_id} status={req.status}")

    status = "approved" if approve else "rejected"
    now = utc_now_iso()
    conn.execute(
        """
        UPDATE control_requests
        SET status=?, updated_ts=?, response_body=?
        WHERE request_id=?
        """,
        (status, now, response_body, request_id),
    )

    meta = parse_meta(
        json.dumps(
            {
                "request_id": request_id,
                "req_type": req.req_type,
                "approve": approve,
                "state": status,
            },
            ensure_ascii=True,
        )
    )
    send_message(
        conn,
        room=req.room,
        sender=responder,
        recipient=req.sender,
        kind=f"{req.req_type}_response",
        body=response_body or status,
        meta_json=meta,
    )

    resolved = get_control_request(conn, request_id=request_id)
    if resolved is None:
        raise SystemExit(f"request vanished after update: {request_id}")
    return resolved


def list_control_requests(
    conn: sqlite3.Connection,
    *,
    room: str,
    recipient: str,
    include_resolved: bool,
    limit: int,
) -> list[ControlRequest]:
    params: list[object] = [room, recipient]
    extra = ""
    if not include_resolved:
        extra = " AND status='pending'"
    params.append(limit)
    rows = conn.execute(
        f"""
        SELECT request_id, room, req_type, sender, recipient, body, status, created_ts, updated_ts, response_body
        FROM control_requests
        WHERE room=? AND recipient=? {extra}
        ORDER BY created_ts ASC
        LIMIT ?
        """,
        params,
    ).fetchall()
    return [ControlRequest(**dict(r)) for r in rows]


def render_text(msg: Message) -> str:
    return f"[{msg.id:06d}] {msg.ts} [{msg.room}] {msg.kind} {msg.sender} -> {msg.recipient}: {msg.body}"


def emit_messages(messages: Iterable[Message], as_json: bool) -> int:
    count = 0
    for msg in messages:
        count += 1
        if as_json:
            print(
                json.dumps(
                    {
                        "id": msg.id,
                        "ts": msg.ts,
                        "room": msg.room,
                        "kind": msg.kind,
                        "sender": msg.sender,
                        "recipient": msg.recipient,
                        "body": msg.body,
                        "meta": json.loads(msg.meta_json or "{}"),
                    },
                    ensure_ascii=True,
                )
            )
        else:
            print(render_text(msg))
    return count


def cmd_init(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)
    print(f"initialized bus: {args.db}")
    return 0


def cmd_register(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)
    touch_member(conn, room=args.room, agent=args.agent, role=args.role, status=args.status)
    conn.commit()
    print(f"registered agent={args.agent} room={args.room} role={args.role} status={args.status}")
    return 0


def cmd_members(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)

    unread_map = {
        str(r["recipient"]): int(r["n"])
        for r in conn.execute(
            """
            SELECT recipient, COUNT(*) AS n
            FROM mailbox
            WHERE room=? AND state='unread'
            GROUP BY recipient
            """,
            (args.room,),
        ).fetchall()
    }

    rows = conn.execute(
        """
        SELECT room, agent, role, status, joined_ts, last_seen_ts
        FROM members
        WHERE room=?
        ORDER BY agent ASC
        """,
        (args.room,),
    ).fetchall()

    if args.json:
        payload = []
        for r in rows:
            payload.append(
                {
                    "room": r["room"],
                    "agent": r["agent"],
                    "role": r["role"],
                    "status": r["status"],
                    "joined_ts": r["joined_ts"],
                    "last_seen_ts": r["last_seen_ts"],
                    "unread": unread_map.get(str(r["agent"]), 0),
                }
            )
        print(json.dumps(payload, ensure_ascii=True))
        return 0

    print(f"room={args.room}")
    print(f"members={len(rows)}")
    for r in rows:
        unread = unread_map.get(str(r["agent"]), 0)
        print(
            f"agent={r['agent']} role={r['role']} status={r['status']} unread={unread} last_seen={r['last_seen_ts']}"
        )
    return 0


def cmd_send(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)
    message_id, fanout_count = send_message(
        conn,
        room=args.room,
        sender=args.sender,
        recipient=args.recipient,
        kind=args.kind,
        body=args.body,
        meta_json=parse_meta(args.meta),
    )
    if args.print_id:
        print(message_id)
    else:
        print(f"sent message #{message_id} fanout={fanout_count}")
    return 0


def cmd_tail(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)
    last_seen = args.since_id

    while True:
        batch = fetch_messages(
            conn,
            room=args.room,
            since_id=last_seen,
            agent=args.agent,
            include_all=args.all,
            limit=args.limit,
        )
        if batch:
            emit_messages(batch, args.json)
            last_seen = batch[-1].id
            sys.stdout.flush()
        if not args.follow:
            break
        time.sleep(args.poll_ms / 1000.0)

    return 0


def cmd_status(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)

    row = conn.execute(
        "SELECT COUNT(*) AS total, COALESCE(MAX(id), 0) AS max_id FROM messages WHERE room=?",
        (args.room,),
    ).fetchone()
    print(f"db={args.db}")
    print(f"room={args.room}")
    print(f"total_messages={row['total']}")
    print(f"last_id={row['max_id']}")

    recipients = conn.execute(
        """
        SELECT recipient, COUNT(*) AS n
        FROM messages
        WHERE room=?
        GROUP BY recipient
        ORDER BY n DESC, recipient ASC
        """,
        (args.room,),
    ).fetchall()
    for r in recipients:
        print(f"recipient[{r['recipient']}]={r['n']}")

    unread = conn.execute(
        """
        SELECT recipient, COUNT(*) AS n
        FROM mailbox
        WHERE room=? AND state='unread'
        GROUP BY recipient
        ORDER BY n DESC, recipient ASC
        """,
        (args.room,),
    ).fetchall()
    for r in unread:
        print(f"unread[{r['recipient']}]={r['n']}")

    members = conn.execute(
        """
        SELECT agent, role, status, last_seen_ts
        FROM members
        WHERE room=?
        ORDER BY agent ASC
        """,
        (args.room,),
    ).fetchall()
    print(f"members={len(members)}")
    for m in members:
        print(f"member[{m['agent']}]={m['role']},{m['status']},{m['last_seen_ts']}")

    pending = conn.execute(
        """
        SELECT recipient, COUNT(*) AS n
        FROM control_requests
        WHERE room=? AND status='pending'
        GROUP BY recipient
        ORDER BY n DESC, recipient ASC
        """,
        (args.room,),
    ).fetchall()
    for p in pending:
        print(f"pending_request[{p['recipient']}]={p['n']}")

    return 0


def cmd_inbox(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)

    items = fetch_inbox(
        conn,
        room=args.room,
        agent=args.agent,
        unread_only=args.unread,
        since_mailbox_id=args.since_mailbox_id,
        limit=args.limit,
    )

    if args.mark_read and items:
        mark_read(
            conn,
            room=args.room,
            agent=args.agent,
            mailbox_ids=[i.mailbox_id for i in items],
            up_to=None,
            mark_all=False,
        )

    if args.json:
        for it in items:
            print(
                json.dumps(
                    {
                        "mailbox_id": it.mailbox_id,
                        "state": it.state,
                        "created_ts": it.created_ts,
                        "read_ts": it.read_ts,
                        "message_id": it.message_id,
                        "ts": it.ts,
                        "kind": it.kind,
                        "sender": it.sender,
                        "recipient": it.recipient,
                        "body": it.body,
                        "meta": json.loads(it.meta_json or "{}"),
                    },
                    ensure_ascii=True,
                )
            )
        return 0

    for it in items:
        print(
            f"[mb:{it.mailbox_id:06d} msg:{it.message_id:06d}] {it.state} {it.ts} {it.kind} {it.sender} -> {it.recipient}: {it.body}"
        )

    if args.mark_read:
        print(f"marked_read={len(items)}")

    return 0


def parse_mailbox_ids(raw_ids: Sequence[int]) -> list[int]:
    out = []
    for value in raw_ids:
        if value <= 0:
            raise SystemExit(f"invalid mailbox id: {value}")
        out.append(int(value))
    return out


def cmd_mark_read(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)

    mailbox_ids = parse_mailbox_ids(args.id)
    updated = mark_read(
        conn,
        room=args.room,
        agent=args.agent,
        mailbox_ids=mailbox_ids,
        up_to=args.up_to,
        mark_all=args.all,
    )
    print(f"marked_read={updated}")
    return 0


def cmd_control_request(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)
    req_id = create_control_request(
        conn,
        room=args.room,
        req_type=args.req_type,
        sender=args.sender,
        recipient=args.recipient,
        body=args.body,
        summary=args.summary,
        request_id=args.request_id,
    )
    conn.commit()
    print(f"request_id={req_id}")
    return 0


def cmd_control_respond(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)

    approve = bool(args.approve)
    body = args.body
    if not body:
        body = "approved" if approve else "rejected"

    resolved = respond_control_request(
        conn,
        request_id=args.request_id,
        responder=args.sender,
        approve=approve,
        response_body=body,
    )
    conn.commit()
    print(f"request_id={resolved.request_id}")
    print(f"status={resolved.status}")
    return 0


def cmd_control_pending(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)

    rows = list_control_requests(
        conn,
        room=args.room,
        recipient=args.agent,
        include_resolved=args.all_status,
        limit=args.limit,
    )

    if args.json:
        print(json.dumps([r.__dict__ for r in rows], ensure_ascii=True))
        return 0

    for r in rows:
        print(
            f"request_id={r.request_id} type={r.req_type} from={r.sender} to={r.recipient} status={r.status} created={r.created_ts}"
        )
        print(f"body={r.body}")
        if r.response_body:
            print(f"response={r.response_body}")
    if not rows:
        print("(no requests)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Codex teams local message bus")
    parser.add_argument("--db", default=DEFAULT_DB, help=f"SQLite file path (default: {DEFAULT_DB})")

    sub = parser.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init", help="initialize database")
    p_init.set_defaults(func=cmd_init)

    p_register = sub.add_parser("register", help="register or refresh a team member")
    p_register.add_argument("--room", default=DEFAULT_ROOM)
    p_register.add_argument("--agent", required=True)
    p_register.add_argument("--role", default="member")
    p_register.add_argument("--status", default="active")
    p_register.set_defaults(func=cmd_register)

    p_members = sub.add_parser("members", help="list room members")
    p_members.add_argument("--room", default=DEFAULT_ROOM)
    p_members.add_argument("--json", action="store_true")
    p_members.set_defaults(func=cmd_members)

    p_send = sub.add_parser("send", help="send message")
    p_send.add_argument("--room", default=DEFAULT_ROOM)
    p_send.add_argument("--from", dest="sender", required=True)
    p_send.add_argument("--to", dest="recipient", default="all")
    p_send.add_argument(
        "--kind",
        default="note",
        help="note|task|question|answer|status|blocker|system|*_request|*_response",
    )
    p_send.add_argument("--body", required=True)
    p_send.add_argument("--meta", default="{}", help="JSON object")
    p_send.add_argument("--print-id", action="store_true")
    p_send.set_defaults(func=cmd_send)

    p_tail = sub.add_parser("tail", help="read recent messages")
    p_tail.add_argument("--room", default=DEFAULT_ROOM)
    p_tail.add_argument("--agent", default="monitor", help="viewer identity for visibility filtering")
    p_tail.add_argument("--since-id", type=int, default=0)
    p_tail.add_argument("--follow", action="store_true")
    p_tail.add_argument("--poll-ms", type=int, default=800)
    p_tail.add_argument("--limit", type=int, default=100)
    p_tail.add_argument("--all", action="store_true", help="ignore recipient filters")
    p_tail.add_argument("--json", action="store_true")
    p_tail.set_defaults(func=cmd_tail)

    p_status = sub.add_parser("status", help="print bus stats")
    p_status.add_argument("--room", default=DEFAULT_ROOM)
    p_status.set_defaults(func=cmd_status)

    p_inbox = sub.add_parser("inbox", help="read mailbox items")
    p_inbox.add_argument("--room", default=DEFAULT_ROOM)
    p_inbox.add_argument("--agent", required=True)
    p_inbox.add_argument("--unread", action="store_true")
    p_inbox.add_argument("--since-mailbox-id", type=int, default=0)
    p_inbox.add_argument("--limit", type=int, default=100)
    p_inbox.add_argument("--mark-read", action="store_true")
    p_inbox.add_argument("--json", action="store_true")
    p_inbox.set_defaults(func=cmd_inbox)

    p_mark = sub.add_parser("mark-read", help="mark mailbox items as read")
    p_mark.add_argument("--room", default=DEFAULT_ROOM)
    p_mark.add_argument("--agent", required=True)
    p_mark.add_argument("--id", type=int, action="append", default=[])
    p_mark.add_argument("--up-to", type=int, default=None)
    p_mark.add_argument("--all", action="store_true")
    p_mark.set_defaults(func=cmd_mark_read)

    p_req = sub.add_parser("control-request", help="create control request")
    p_req.add_argument("--room", default=DEFAULT_ROOM)
    p_req.add_argument("--type", dest="req_type", choices=CONTROL_TYPES, required=True)
    p_req.add_argument("--from", dest="sender", required=True)
    p_req.add_argument("--to", dest="recipient", required=True)
    p_req.add_argument("--body", required=True)
    p_req.add_argument("--summary", default="")
    p_req.add_argument("--request-id", default="")
    p_req.set_defaults(func=cmd_control_request)

    p_resp = sub.add_parser("control-respond", help="respond to control request")
    p_resp.add_argument("--request-id", required=True)
    p_resp.add_argument("--from", dest="sender", required=True)
    response_group = p_resp.add_mutually_exclusive_group(required=True)
    response_group.add_argument("--approve", action="store_true")
    response_group.add_argument("--reject", action="store_true")
    p_resp.add_argument("--body", default="")
    p_resp.set_defaults(func=cmd_control_respond)

    p_pending = sub.add_parser("control-pending", help="list control requests for agent")
    p_pending.add_argument("--room", default=DEFAULT_ROOM)
    p_pending.add_argument("--agent", required=True)
    p_pending.add_argument("--all-status", action="store_true")
    p_pending.add_argument("--limit", type=int, default=100)
    p_pending.add_argument("--json", action="store_true")
    p_pending.set_defaults(func=cmd_control_pending)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
