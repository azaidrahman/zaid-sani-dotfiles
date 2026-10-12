#!/usr/bin/env python3
"""Read and write the worklog CSV at <vault>/2-Journals/worklog.csv.

Usage:
  worklog-csv.py read  <YYYY-MM-DD>          print the rows for one day as JSON
  worklog-csv.py write <YYYY-MM-DD>          read a JSON object from stdin and
                                             replace the matching parts of that day

JSON input for write (both keys optional):
  {
    "tasks": [{"key": "GTI-1", "summary": "label", "status": "In Progress", "done": false}],
    "recap": "Up to three sentences.",
    "next_day": "One line."
  }
  "tasks" replaces every task row for the day. Omit it to keep the task rows.
  "recap" replaces the recap row for the day. Omit it to keep the recap row.
  A non-Jira task has an empty "key" and an empty "status".

Rows are sorted by date. Re-running write for the same day never duplicates rows.
"""

import csv
import datetime
import json
import os
import sys
from pathlib import Path

FIELDS = ["date", "kind", "key", "summary", "status", "done", "note"]


def csv_path():
    vault = os.environ.get("OBSIDIAN_VAULT", str(Path.home() / "vaults" / "Polaris"))
    return Path(vault) / "2-Journals" / "worklog.csv"


def load():
    path = csv_path()
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def save(rows):
    path = csv_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def task_row(day, task):
    return {
        "date": day,
        "kind": "task",
        "key": task.get("key", ""),
        "summary": task["summary"],
        "status": task.get("status", ""),
        "done": "true" if task.get("done") else "false",
        "note": "",
    }


def recap_row(day, text, next_day):
    return {
        "date": day,
        "kind": "recap",
        "key": "",
        "summary": text,
        "status": "",
        "done": "",
        "note": next_day,
    }


def read(day):
    rows = [r for r in load() if r["date"] == day]
    print(json.dumps(rows, ensure_ascii=False, indent=2))


def write(day):
    data = json.load(sys.stdin)
    rows = load()
    today = [r for r in rows if r["date"] == day]
    others = [r for r in rows if r["date"] != day]

    if "tasks" in data:
        day_tasks = [task_row(day, t) for t in data["tasks"]]
    else:
        day_tasks = [r for r in today if r["kind"] == "task"]

    if "recap" in data:
        day_recap = [recap_row(day, data["recap"], data.get("next_day", ""))] if data["recap"] else []
    else:
        day_recap = [r for r in today if r["kind"] == "recap"]

    merged = sorted(others + day_tasks + day_recap, key=lambda r: r["date"])
    save(merged)
    print(f"wrote {len(day_tasks)} task row(s) and {len(day_recap)} recap row(s) for {day} to {csv_path()}")


def main(argv):
    if len(argv) != 3 or argv[1] not in ("read", "write"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        day = datetime.date.fromisoformat(argv[2]).isoformat()
    except ValueError:
        print(f"not a date: {argv[2]} (want YYYY-MM-DD)", file=sys.stderr)
        return 2
    if argv[1] == "read":
        read(day)
    else:
        write(day)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
