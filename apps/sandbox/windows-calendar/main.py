#!/usr/bin/env python3
"""Simple desktop calendar app for Windows (Tkinter)."""

from __future__ import annotations

import calendar
import tkinter as tk
from datetime import date
from tkinter import messagebox
from tkinter import ttk

from calendar_core import EventStore
from calendar_core import date_key
from calendar_core import month_grid


class CalendarApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Codex Windows Calendar")
        self.root.geometry("980x620")
        self.root.minsize(860, 540)

        today = date.today()
        self.year = today.year
        self.month = today.month
        self.day = today.day

        self.store = EventStore()
        self.day_buttons: dict[int, tk.Button] = {}
        self.list_rows: list[dict] = []
        self.selected_event_id: str = ""
        self.calendar_frame: ttk.Frame | None = None

        self.month_text = tk.StringVar()
        self.selected_date_text = tk.StringVar()
        self.status_text = tk.StringVar(value=f"저장 경로: {self.store.file_path}")
        self.title_var = tk.StringVar()

        self._build_ui()
        self.refresh_calendar()
        self.refresh_events()

    def _build_ui(self) -> None:
        wrapper = ttk.Frame(self.root, padding=12)
        wrapper.pack(fill=tk.BOTH, expand=True)

        top = ttk.Frame(wrapper)
        top.pack(fill=tk.X, pady=(0, 10))

        ttk.Button(top, text="◀ 이전 달", command=lambda: self.shift_month(-1)).pack(side=tk.LEFT)
        ttk.Label(top, textvariable=self.month_text, font=("맑은 고딕", 14, "bold")).pack(side=tk.LEFT, padx=14)
        ttk.Button(top, text="다음 달 ▶", command=lambda: self.shift_month(1)).pack(side=tk.LEFT)
        ttk.Button(top, text="오늘로 이동", command=self.go_today).pack(side=tk.RIGHT)

        body = ttk.Frame(wrapper)
        body.pack(fill=tk.BOTH, expand=True)
        body.columnconfigure(0, weight=3)
        body.columnconfigure(1, weight=2)
        body.rowconfigure(0, weight=1)

        cal_frame = ttk.Frame(body)
        cal_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 10))
        self.calendar_frame = cal_frame
        for col in range(7):
            cal_frame.columnconfigure(col, weight=1)
        for row in range(1, 8):
            cal_frame.rowconfigure(row, weight=1)

        weekdays = ["월", "화", "수", "목", "금", "토", "일"]
        for col, name in enumerate(weekdays):
            ttk.Label(cal_frame, text=name, anchor=tk.CENTER).grid(row=0, column=col, sticky="nsew", padx=2, pady=2)

        for row in range(1, 7):
            for col in range(7):
                btn = tk.Button(
                    cal_frame,
                    text="",
                    relief=tk.RAISED,
                    command=lambda d=0: self.select_day(d),
                    anchor="n",
                    justify=tk.LEFT,
                    font=("맑은 고딕", 10),
                )
                btn.grid(row=row, column=col, sticky="nsew", padx=2, pady=2)

        details = ttk.LabelFrame(body, text="일정", padding=10)
        details.grid(row=0, column=1, sticky="nsew")
        details.columnconfigure(0, weight=1)
        details.rowconfigure(3, weight=1)

        ttk.Label(details, textvariable=self.selected_date_text, font=("맑은 고딕", 11, "bold")).grid(
            row=0, column=0, sticky="w", pady=(0, 8)
        )

        self.event_list = tk.Listbox(details, height=10)
        self.event_list.grid(row=1, column=0, sticky="nsew")
        self.event_list.bind("<<ListboxSelect>>", self.on_list_select)

        ttk.Label(details, text="제목").grid(row=2, column=0, sticky="w", pady=(10, 2))
        ttk.Entry(details, textvariable=self.title_var).grid(row=3, column=0, sticky="ew")

        ttk.Label(details, text="메모").grid(row=4, column=0, sticky="w", pady=(10, 2))
        self.notes_text = tk.Text(details, height=7, wrap=tk.WORD)
        self.notes_text.grid(row=5, column=0, sticky="nsew")

        action_row = ttk.Frame(details)
        action_row.grid(row=6, column=0, sticky="ew", pady=(10, 0))
        for col in range(3):
            action_row.columnconfigure(col, weight=1)
        ttk.Button(action_row, text="추가", command=self.add_event).grid(row=0, column=0, sticky="ew", padx=(0, 4))
        ttk.Button(action_row, text="수정", command=self.update_event).grid(row=0, column=1, sticky="ew", padx=4)
        ttk.Button(action_row, text="삭제", command=self.delete_event).grid(row=0, column=2, sticky="ew", padx=(4, 0))

        ttk.Label(wrapper, textvariable=self.status_text).pack(fill=tk.X, pady=(10, 0))

    def shift_month(self, delta: int) -> None:
        month = self.month + delta
        year = self.year
        if month < 1:
            month = 12
            year -= 1
        elif month > 12:
            month = 1
            year += 1
        self.year = year
        self.month = month
        max_day = calendar.monthrange(self.year, self.month)[1]
        self.day = min(self.day, max_day)
        self.refresh_calendar()
        self.refresh_events()

    def go_today(self) -> None:
        today = date.today()
        self.year, self.month, self.day = today.year, today.month, today.day
        self.refresh_calendar()
        self.refresh_events()

    def selected_key(self) -> str:
        return date_key(self.year, self.month, self.day)

    def refresh_calendar(self) -> None:
        self.month_text.set(f"{self.year}년 {self.month}월")
        self.selected_date_text.set(f"선택 날짜: {self.selected_key()}")

        for btn in self.day_buttons.values():
            btn.destroy()
        self.day_buttons.clear()

        grid = month_grid(self.year, self.month, firstweekday=0)
        while len(grid) < 6:
            grid.append([0, 0, 0, 0, 0, 0, 0])
        events_day = self.store.dates_with_events(self.year, self.month)

        if self.calendar_frame is None:
            return
        cal_frame = self.calendar_frame
        for row_idx, week in enumerate(grid, start=1):
            for col_idx, day_value in enumerate(week):
                txt = "" if day_value == 0 else str(day_value)
                btn = tk.Button(
                    cal_frame,
                    text=txt,
                    relief=tk.RAISED,
                    command=lambda d=day_value: self.select_day(d),
                    anchor="n",
                    justify=tk.LEFT,
                    font=("맑은 고딕", 10),
                    bg="#ffffff",
                )
                if day_value == 0:
                    btn.configure(state=tk.DISABLED, bg="#f2f2f2")
                else:
                    if day_value in events_day:
                        btn.configure(bg="#dff0d8")
                    if day_value == self.day:
                        btn.configure(bg="#b7e1ff")
                btn.grid(row=row_idx, column=col_idx, sticky="nsew", padx=2, pady=2)
                if day_value > 0:
                    self.day_buttons[day_value] = btn

    def select_day(self, day_value: int) -> None:
        if day_value <= 0:
            return
        self.day = day_value
        self.refresh_calendar()
        self.refresh_events()

    def refresh_events(self) -> None:
        key = self.selected_key()
        rows = self.store.list_for_date(key)
        self.list_rows = rows
        self.selected_event_id = ""
        self.event_list.delete(0, tk.END)
        for row in rows:
            title = str(row.get("title", "")).strip() or "(제목 없음)"
            note_preview = str(row.get("notes", "")).strip().replace("\n", " ")
            if len(note_preview) > 24:
                note_preview = note_preview[:24] + "..."
            label = title if not note_preview else f"{title}  ·  {note_preview}"
            self.event_list.insert(tk.END, label)

        self.title_var.set("")
        self.notes_text.delete("1.0", tk.END)
        self.selected_date_text.set(f"선택 날짜: {key} (일정 {len(rows)}개)")

    def on_list_select(self, _event: object) -> None:
        if not self.event_list.curselection():
            return
        idx = int(self.event_list.curselection()[0])
        if idx < 0 or idx >= len(self.list_rows):
            return
        row = self.list_rows[idx]
        self.selected_event_id = str(row.get("id", ""))
        self.title_var.set(str(row.get("title", "")))
        self.notes_text.delete("1.0", tk.END)
        self.notes_text.insert("1.0", str(row.get("notes", "")))

    def _input_values(self) -> tuple[str, str]:
        title = self.title_var.get().strip()
        notes = self.notes_text.get("1.0", tk.END).strip()
        return title, notes

    def add_event(self) -> None:
        title, notes = self._input_values()
        if not title:
            messagebox.showwarning("입력 필요", "제목을 입력하세요.")
            return
        key = self.selected_key()
        self.store.add_event(key, title, notes)
        self.status_text.set(f"추가됨: {key} / {title}")
        self.refresh_calendar()
        self.refresh_events()

    def update_event(self) -> None:
        if not self.selected_event_id:
            messagebox.showwarning("선택 필요", "수정할 일정을 먼저 선택하세요.")
            return
        title, notes = self._input_values()
        if not title:
            messagebox.showwarning("입력 필요", "제목을 입력하세요.")
            return
        key = self.selected_key()
        ok = self.store.update_event(key, self.selected_event_id, title, notes)
        if not ok:
            messagebox.showerror("수정 실패", "선택한 일정이 더 이상 존재하지 않습니다.")
            return
        self.status_text.set(f"수정됨: {key} / {title}")
        self.refresh_calendar()
        self.refresh_events()

    def delete_event(self) -> None:
        if not self.selected_event_id:
            messagebox.showwarning("선택 필요", "삭제할 일정을 먼저 선택하세요.")
            return
        key = self.selected_key()
        ok = self.store.delete_event(key, self.selected_event_id)
        if not ok:
            messagebox.showerror("삭제 실패", "선택한 일정이 더 이상 존재하지 않습니다.")
            return
        self.status_text.set(f"삭제됨: {key}")
        self.refresh_calendar()
        self.refresh_events()


def main() -> None:
    root = tk.Tk()
    app = CalendarApp(root)
    root.protocol("WM_DELETE_WINDOW", root.destroy)
    root.mainloop()


if __name__ == "__main__":
    main()
