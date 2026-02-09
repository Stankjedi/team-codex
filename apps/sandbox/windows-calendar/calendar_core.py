#!/usr/bin/env python3
"""Core logic for a Windows-friendly desktop calendar app."""

from __future__ import annotations

import calendar
import json
import os
import tempfile
import uuid
from dataclasses import dataclass
from datetime import datetime
from datetime import timezone
from pathlib import Path
from typing import Any


def default_data_path() -> Path:
    if os.name == "nt":
        appdata = os.environ.get("APPDATA")
        base = Path(appdata) if appdata else Path.home()
        return base / "CodexCalendar" / "events.json"
    return Path.home() / ".codex-calendar" / "events.json"


def date_key(year: int, month: int, day: int) -> str:
    return f"{year:04d}-{month:02d}-{day:02d}"


def month_grid(year: int, month: int, firstweekday: int = 0) -> list[list[int]]:
    cal = calendar.Calendar(firstweekday=firstweekday)
    return cal.monthdayscalendar(year, month)


@dataclass
class EventItem:
    id: str
    title: str
    notes: str
    updated_at: str

    @classmethod
    def new(cls, title: str, notes: str) -> "EventItem":
        return cls(
            id=uuid.uuid4().hex[:12],
            title=title.strip(),
            notes=notes.strip(),
            updated_at=datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        )

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "notes": self.notes,
            "updated_at": self.updated_at,
        }


class EventStore:
    def __init__(self, file_path: Path | None = None) -> None:
        self.file_path = file_path or default_data_path()
        self._events: dict[str, list[dict[str, Any]]] = {}
        self.load()

    def load(self) -> None:
        if not self.file_path.exists():
            self._events = {}
            return
        try:
            raw = self.file_path.read_text(encoding="utf-8")
            decoded = json.loads(raw)
        except (OSError, json.JSONDecodeError):
            self._events = {}
            return
        if not isinstance(decoded, dict):
            self._events = {}
            return
        clean: dict[str, list[dict[str, Any]]] = {}
        for key, value in decoded.items():
            if not isinstance(key, str) or not isinstance(value, list):
                continue
            valid_items: list[dict[str, Any]] = []
            for item in value:
                if not isinstance(item, dict):
                    continue
                if not isinstance(item.get("id", ""), str):
                    continue
                title = str(item.get("title", "")).strip()
                notes = str(item.get("notes", "")).strip()
                updated = str(item.get("updated_at", "")).strip()
                valid_items.append(
                    {
                        "id": str(item.get("id")),
                        "title": title,
                        "notes": notes,
                        "updated_at": updated,
                    }
                )
            clean[key] = valid_items
        self._events = clean

    def save(self) -> None:
        self.file_path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(self._events, ensure_ascii=False, indent=2)
        fd, tmp_name = tempfile.mkstemp(prefix=".events-", suffix=".json", dir=str(self.file_path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(payload)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_name, self.file_path)
        finally:
            if os.path.exists(tmp_name):
                try:
                    os.remove(tmp_name)
                except OSError:
                    pass

    def list_for_date(self, key: str) -> list[dict[str, Any]]:
        items = self._events.get(key, [])
        return [dict(item) for item in items]

    def dates_with_events(self, year: int, month: int) -> set[int]:
        prefix = f"{year:04d}-{month:02d}-"
        out: set[int] = set()
        for key, entries in self._events.items():
            if not key.startswith(prefix):
                continue
            if not isinstance(entries, list) or len(entries) == 0:
                continue
            try:
                day = int(key.split("-")[2])
            except (IndexError, ValueError):
                continue
            out.add(day)
        return out

    def add_event(self, key: str, title: str, notes: str) -> dict[str, Any]:
        item = EventItem.new(title=title, notes=notes).as_dict()
        bucket = self._events.setdefault(key, [])
        bucket.append(item)
        self.save()
        return dict(item)

    def update_event(self, key: str, event_id: str, title: str, notes: str) -> bool:
        bucket = self._events.get(key, [])
        for item in bucket:
            if str(item.get("id", "")) != event_id:
                continue
            item["title"] = title.strip()
            item["notes"] = notes.strip()
            item["updated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
            self.save()
            return True
        return False

    def delete_event(self, key: str, event_id: str) -> bool:
        bucket = self._events.get(key, [])
        keep = [item for item in bucket if str(item.get("id", "")) != event_id]
        if len(keep) == len(bucket):
            return False
        if keep:
            self._events[key] = keep
        else:
            self._events.pop(key, None)
        self.save()
        return True
