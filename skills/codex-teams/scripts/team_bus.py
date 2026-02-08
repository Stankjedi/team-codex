#!/usr/bin/env python3
"""Local real-time message bus for Codex team sessions.

Store all inter-agent messages in SQLite so each agent can tail updates in near real time.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable


DEFAULT_DB = ".codex-teams/bus.sqlite"
DEFAULT_ROOM = "main"


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
    conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_room_id ON messages(room, id);")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_recipient ON messages(recipient, id);")
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
    conn.commit()
    return int(cur.lastrowid)


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


def cmd_send(args: argparse.Namespace) -> int:
    conn = connect(args.db)
    ensure_schema(conn)
    message_id = insert_message(
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
        print(f"sent message #{message_id}")
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

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Codex teams local message bus")
    parser.add_argument("--db", default=DEFAULT_DB, help=f"SQLite file path (default: {DEFAULT_DB})")

    sub = parser.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init", help="initialize database")
    p_init.set_defaults(func=cmd_init)

    p_send = sub.add_parser("send", help="send message")
    p_send.add_argument("--room", default=DEFAULT_ROOM)
    p_send.add_argument("--from", dest="sender", required=True)
    p_send.add_argument("--to", dest="recipient", default="all")
    p_send.add_argument("--kind", default="note", help="note|task|question|answer|status|blocker|system")
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

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
