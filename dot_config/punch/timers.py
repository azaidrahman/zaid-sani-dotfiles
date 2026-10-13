"""Read the state of the Clock.app timers.

Clock.app is not scriptable. The timer daemon keeps its state in a plist, so
this module reads that plist.
"""
import plistlib
from datetime import datetime, timezone
from pathlib import Path

PLIST = Path.home() / "Library/Preferences/com.apple.mobiletimerd.plist"


def read_timers(data: bytes) -> list[dict]:
    """Return every timer in the plist bytes."""
    root = plistlib.loads(data)
    entries = root.get("MTTimers", {}).get("MTTimers", [])
    out = []
    for entry in entries:
        t = entry.get("$MTTimer")
        if not t:
            continue
        fired = t.get("MTTimerFiredDate")
        if fired is not None and fired.tzinfo is None:
            fired = fired.replace(tzinfo=timezone.utc)
        out.append({
            "id": t.get("MTTimerID", ""),
            "state": int(t.get("MTTimerState", 1)),
            "duration": float(t.get("MTTimerDuration", 0)),
            "title": t.get("MTTimerTitle", ""),
            "fired_date": fired,
        })
    return out


def active(timers: list[dict]) -> list[dict]:
    """Keep only the running or paused timers. State 1 means idle."""
    return [t for t in timers if t["state"] >= 2]


def load() -> list[dict]:
    """Read the timers from the plist of this machine."""
    return read_timers(PLIST.read_bytes())


if __name__ == "__main__":
    import json
    print(json.dumps([{**t, "fired_date": str(t["fired_date"])}
                      for t in load()], indent=2))
