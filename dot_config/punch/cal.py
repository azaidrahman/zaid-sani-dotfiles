"""Write the session to Calendar.app.

Calendar.app syncs to Google and Dot.app reads the same store, so this needs no
API credentials.
"""
import subprocess
from datetime import datetime

CALENDAR = "Task Punch"

_CREATE = '''
on run argv
  set t to item 1 of argv
  set s to current date
  set year of s to (item 2 of argv) as integer
  set month of s to (item 3 of argv) as integer
  set day of s to (item 4 of argv) as integer
  set hours of s to (item 5 of argv) as integer
  set minutes of s to (item 6 of argv) as integer
  set seconds of s to 0
  set e to s + ((item 7 of argv) as integer) * minutes
  tell application "Calendar" to tell calendar "%s"
    set ev to make new event with properties {summary:t, start date:s, end date:e}
    return uid of ev
  end tell
end run
''' % CALENDAR

_CANCEL = '''
on run argv
  set u to item 1 of argv
  set t to item 2 of argv
  tell application "Calendar" to tell calendar "%s"
    set matches to (every event whose uid is u)
    if matches is {} then return "missing"
    set ev to item 1 of matches
    set summary of ev to t & " (cancelled)"
    set end date of ev to (current date)
    return "ok"
  end tell
end run
''' % CALENDAR


def _osascript(script: str, *args: str) -> str:
    r = subprocess.run(["osascript", "-", *args], input=script,
                       capture_output=True, text=True)
    if r.returncode != 0:
        # osascript writes the reason to stderr. Keep it, or the caller
        # sees an exit code and no cause.
        raise RuntimeError(
            f"osascript failed with status {r.returncode}: "
            f"{r.stderr.strip() or 'no output'}")
    return r.stdout.strip()


def create_event(topic: str, start: datetime, end: datetime) -> str:
    """Make the event and return its UID.

    The date is built from components, because AppleScript parses a date
    string with the locale of the machine.
    """
    dur = round((end - start).total_seconds() / 60)
    return _osascript(_CREATE, topic, str(start.year), str(start.month),
                      str(start.day), str(start.hour), str(start.minute),
                      str(dur))


def mark_cancelled(uid: str, topic: str) -> str:
    """Retitle the event and move its end to now. The event is never deleted,
    so a cancelled session stays countable."""
    return _osascript(_CANCEL, uid, topic)
