#!/usr/bin/python3
"""Build the session note and the URL that writes it."""
import json
from datetime import datetime
from urllib.parse import quote

FOLDER = "5-Workbook/worklog"
VAULT = "Polaris"


def stamp(moment: datetime) -> str:
    """Return the readable part of a session name, for example "MON 7.57AM"."""
    return moment.strftime("%a %-I.%M%p").upper()


def build_note(topic: str, start: datetime, end: datetime,
               status: str, distraction, source: str = "live",
               focus: str = "") -> tuple[str, str]:
    """Return the path in the vault and the content of the note.

    The focus is what the user meant to work on. It goes into the
    frontmatter only when the user wrote one. JSON text is valid YAML, so
    the quotes keep a colon or a hash in the focus from breaking the field.
    """
    hours = round((end - start).total_seconds() / 3600, 2)
    # The date leads so the names sort by day. The day name and the clock
    # time follow, so a person can read the time of the session at a glance.
    name = f"{start:%Y-%m-%d} {stamp(start)} {topic}.md"
    focus_line = f"focus: {json.dumps(focus, ensure_ascii=False)}\n" if focus else ""
    body = (
        "---\n"
        "tags:\n"
        "  - work/session\n"
        f"date: {start:%Y-%m-%d}\n"
        f'start: "{start:%H:%M}"\n'
        f'end: "{end:%H:%M}"\n'
        f"hours: {hours}\n"
        f"topic: {topic}\n"
        f"{focus_line}"
        f"status: {status}\n"
        f"distraction:{'' if distraction is None else ' ' + str(distraction)}\n"
        f"source: {source}\n"
        "---\n"
    )
    return f"{FOLDER}/{name}", body


def adv_uri(filepath: str, data: str) -> str:
    """Return the Advanced URI that makes the note. The vault is named, not
    given as a path, so this works on every machine."""
    return (f"obsidian://adv-uri?vault={VAULT}"
            f"&filepath={quote(filepath, safe='')}"
            f"&data={quote(data, safe='')}&mode=new")
