#!/usr/bin/env python3

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from calendar_core import EventStore
from calendar_core import date_key
from calendar_core import month_grid


class CalendarCoreTests(unittest.TestCase):
    def test_date_key(self) -> None:
        self.assertEqual(date_key(2026, 2, 9), "2026-02-09")

    def test_month_grid_contains_days(self) -> None:
        grid = month_grid(2026, 2, firstweekday=0)
        flat = [d for week in grid for d in week if d > 0]
        self.assertIn(1, flat)
        self.assertIn(28, flat)
        self.assertNotIn(29, flat)

    def test_event_store_lifecycle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = EventStore(Path(tmp) / "events.json")
            key = "2026-02-09"

            created = store.add_event(key, "회의", "스프린트 점검")
            self.assertTrue(created["id"])

            rows = store.list_for_date(key)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["title"], "회의")

            updated = store.update_event(key, created["id"], "회의-수정", "메모 변경")
            self.assertTrue(updated)
            rows = store.list_for_date(key)
            self.assertEqual(rows[0]["title"], "회의-수정")

            deleted = store.delete_event(key, created["id"])
            self.assertTrue(deleted)
            rows = store.list_for_date(key)
            self.assertEqual(rows, [])

    def test_dates_with_events(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = EventStore(Path(tmp) / "events.json")
            store.add_event("2026-03-01", "a", "")
            store.add_event("2026-03-15", "b", "")
            store.add_event("2026-04-01", "c", "")
            found = store.dates_with_events(2026, 3)
            self.assertEqual(found, {1, 15})


if __name__ == "__main__":
    unittest.main()

