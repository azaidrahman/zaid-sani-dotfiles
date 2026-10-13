"""Decide how a punch session ended."""
from datetime import datetime, timedelta

# A fired date must fall near the planned end. Clock.app can hold old timers.
FIRE_WINDOW = timedelta(minutes=5)

# The machine must be idle this long before a running session is cancelled.
IDLE_LIMIT = 600


def classify(timer, planned_end: datetime, now: datetime,
             idle_seconds: float, idle_limit: int = IDLE_LIMIT):
    """Return the state of the session and the time it ended.

    The states are running, completed, and cancelled.
    """
    # A timer that rang at the planned end proves the session ran. This
    # comes first, because the user can leave the desk and still complete
    # the session.
    if timer is not None and timer["state"] < 2:
        fired = timer.get("fired_date")
        if fired is not None and abs(fired - planned_end) <= FIRE_WINDOW:
            return "completed", fired

    if timer is not None and timer["state"] >= 2 and idle_seconds < idle_limit:
        return "running", now

    # An idle machine ended the session when the user left it. The end
    # never goes past the planned end, or a state file that nobody read
    # for a day logs a day of study.
    end = now - timedelta(seconds=idle_seconds) if idle_seconds >= idle_limit else now
    return "cancelled", min(end, planned_end)
