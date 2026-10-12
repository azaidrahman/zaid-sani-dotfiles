#!/usr/bin/python3
"""Keep each session as one row in the sessions CSV of the vault."""
import csv
from datetime import date, datetime, time
from pathlib import Path

FILE = Path.home() / "vaults/Polaris/5-Workbook/sessions.csv"
FIELDS = ["date", "start", "end", "hours", "topic", "focus", "status",
          "distraction", "source", "note"]


def build_row(topic: str, start: datetime, end: datetime,
              status: str, distraction, source: str = "live",
              focus: str = "") -> dict:
    """Return the row of one session.

    The focus is what the user meant to work on. It is empty when the user
    wrote none. A cancelled session has no distraction score. The note
    column is free text that the user may add later, so a live session
    leaves it empty.
    """
    return {
        "date": f"{start:%Y-%m-%d}",
        "start": f"{start:%H:%M}",
        "end": f"{end:%H:%M}",
        "hours": round((end - start).total_seconds() / 3600, 2),
        "topic": topic,
        "focus": focus,
        "status": status,
        "distraction": "" if distraction is None else distraction,
        "source": source,
        "note": "",
    }


def append(row: dict, path: Path | None = None) -> None:
    """Add the row at the end of the CSV. Write the header first if the file is new."""
    path = path or FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    is_new = not path.exists() or path.stat().st_size == 0
    with path.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        if is_new:
            writer.writeheader()
        writer.writerow(row)


def read(path: Path | None = None) -> list:
    """Return every row of the CSV, or an empty list when there is no file."""
    path = path or FILE
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def span(row: dict) -> tuple:
    """Return the start and the end of a row as datetimes on its date."""
    day = date.fromisoformat(row["date"])
    return (datetime.combine(day, time.fromisoformat(row["start"])),
            datetime.combine(day, time.fromisoformat(row["end"])))
