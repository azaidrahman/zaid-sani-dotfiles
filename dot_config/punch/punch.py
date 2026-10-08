#!/usr/bin/python3
"""Start and end a punch session."""
import argparse
import json
import logging
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import cal
import note
import outcome
import punchtime
import timers

log = logging.getLogger("punch")

LOG_PATH = Path.home() / ".local/state/punch.log"
STATE = Path.home() / ".local/state/punch.json"
# check() renames STATE to this while it ends the session. A crash during
# the distraction dialog can leave the claim behind, so every reader looks
# at both files.
CLAIM = STATE.with_suffix(".ending.json")
SHORTCUT = "Start Study Timer"
# One Clock action: Cancel Timer. It stops the most recent timer.
STOP_SHORTCUT = "Stop Study Timer"
# Seconds that the start waits for the Clock.app plist, and that a stop
# waits for the timer to leave it.
START_TRIES = 20
STOP_TRIES = 10
# The options of the prompt after a start that found no new timer.
TIMER_RESET = "Reset timer & retry"
TIMER_GIVE_UP = "Give up"
TOPICS = Path.home() / "vaults/Polaris/5-Workbook/worklog/Topics.md"
WORKLOG = TOPICS.parent
PRESETS = ["25", "50", "60", "90"]

# The HUD binary shows the toast, the list picker, and the score picker.
# It reads one key press, so the pickers need no mouse.
HUD = Path.home() / ".config/karabiner/scripts/timer-hud"
# The resync runs as its own process, because it takes minutes and the
# HUD closes at once.
RESYNC_SCRIPT = Path(__file__).with_name("resync.py")

# The row of step 1 that is not a topic.
OTHER = "other…"
# The HUD prints this token when the user holds control and presses r.
RESYNC_KEY = "r=resync"

# The distraction dialog closes itself after this many seconds, so a timer
# that rings at an empty desk never blocks the next session.
DIALOG_TIMEOUT = 180

# The score a session takes when nobody answers the distraction dialog.
AWAY_DISTRACTION = 5

# A live session offers to open the Moodist ambient sound page. The page
# cannot start the sound itself, because the browser blocks audio that no
# click starts. The user presses play or shuffle on the page.
MOODIST_URL = "https://moodist.mvze.net/"
MOODIST_OPEN = "Open Moodist"

# The interactive start asks four questions: the topic, the focus, the
# timebox, and the start time. The user walks the steps with the n and the
# p keys.
STEPS = 4

# The pill is a small floating HUD that shows the title and the time left
# of the open session. Its flag file hides it. The pill reads the flag on
# each tick, so the toggle needs no restart.
PILL_FLAG = Path.home() / ".local/state/punch-pill.hidden"
PILL_HIDE = "Hide pill"
PILL_SHOW = "Show pill"


class _Back:
    """The answer of a prompt that the user left with the p key."""

    def __repr__(self) -> str:
        return "BACK"


# One shared value, so a caller can test the answer with `is BACK`.
BACK = _Back()


class _Resync:
    """The answer of a pick that the user left with the resync key."""

    def __repr__(self) -> str:
        return "RESYNC"


# One shared value, so a caller can test the answer with `is RESYNC`.
RESYNC = _Resync()


def step_label(number: int, chosen: list[str]) -> str:
    """Return the label that names the step and what the user picked.

    The HUD shows this above every prompt, so the user always reads the
    position in the flow and the answers that already stand.
    """
    trail = " · ".join(c for c in chosen if c)
    label = f"Step {number} of {STEPS}"
    return f"{label} · {trail}" if trail else label


def advance(step: int, answer) -> int:
    """Return the number of the next step for one answer.

    The p key goes back one step. Step 1 has no step before it, so it
    stays where it is.
    """
    if answer is BACK:
        return max(1, step - 1)
    return step + 1


def open_state():
    """Return the path and the content of the open session, or None."""
    for path in (STATE, CLAIM):
        try:
            return path, json.loads(path.read_text())
        except FileNotFoundError:
            continue
    return None


def _run_shortcut(name: str, text: str = "") -> None:
    url = f"shortcuts://run-shortcut?name={name.replace(' ', '%20')}"
    if text:
        url += f"&input=text&text={text}"
    subprocess.run(["open", url], check=True)


def _start_timer(minutes: int) -> None:
    _run_shortcut(SHORTCUT, str(minutes))


def _stop_timer() -> None:
    """Cancel the most recent Clock.app timer. The Clock action takes no
    timer id, so the caller checks that the recent one is the right one."""
    _run_shortcut(STOP_SHORTCUT)


def stale_timer(minutes: int, found: list[dict]):
    """Return the active timer with the length of the new session, or None.

    Clock.app keeps one timer per length. A start with the same length as a
    timer that still runs does nothing, so that timer is stale: a session
    that closed before its timer ended left it behind.
    """
    want = minutes * 60
    return next((t for t in timers.active(found) if t["duration"] == want),
                None)


def _wait_for_timer(before: set, tries: int) -> str:
    """Return the id of a timer that is active and not in `before`."""
    for _ in range(tries):
        time.sleep(1)
        new = [t for t in timers.active(timers.load()) if t["id"] not in before]
        if new:
            return new[0]["id"]
    return ""


def _wait_until_stopped(timer_id: str, tries: int) -> bool:
    for _ in range(tries):
        time.sleep(1)
        if all(t["id"] != timer_id for t in timers.active(timers.load())):
            return True
    return False


def _stop_stale_timer(stale: dict) -> None:
    """Stop a stale timer and wait until the plist shows it stopped.

    The caller takes its snapshot after this, because Clock.app can give
    the restarted timer the id of the stopped one.
    """
    log.warning("a stale %d min timer %s still runs; stopping it",
                stale["duration"] // 60, stale["id"])
    _stop_timer()
    if not _wait_until_stopped(stale["id"], STOP_TRIES):
        log.warning("the stale timer %s did not stop in time", stale["id"])


def restart_timer(minutes: int) -> str:
    """Stop the timer that blocks a start, then start a new one.

    This is the reset of a start that found no new timer. Return the id
    of the new timer, or an empty string.
    """
    stale = stale_timer(minutes, timers.load())
    if stale is not None:
        _stop_stale_timer(stale)
    else:
        log.warning("no stale %d min timer found; stopping the recent one",
                    minutes)
        _stop_timer()
    before = {t["id"] for t in timers.active(timers.load())}
    _start_timer(minutes)
    return _wait_for_timer(before, START_TRIES)


def ask_timer_reset(topic: str) -> bool:
    """Ask whether to stop the blocking timer and start again.

    The return key takes the reset, because the common cause is a timer
    that a closed session left behind. Escape and a timeout give up.
    """
    prompt = f"{topic} — Clock.app started no timer"
    return choose(prompt, [TIMER_RESET, TIMER_GIVE_UP]) == TIMER_RESET


def stop_session_timer(s: dict) -> None:
    """Stop the timer of a session that closes before its timer ends.

    A timer that already fired is left alone. A failure is logged, because
    the close must go on without the timer.
    """
    timer_id = s.get("timer_id", "")
    if not timer_id:
        return
    try:
        if any(t["id"] == timer_id for t in timers.active(timers.load())):
            _stop_timer()
            log.info("timer %s stopped", timer_id)
    except Exception as e:
        log.warning("failed to stop the timer %s: %s", timer_id, e)


def day_notes(day) -> list:
    """Return (topic, start, end) for each session note of the day."""
    out = []
    for path in sorted(WORKLOG.glob(f"{day:%Y-%m-%d} *.md")):
        parsed = punchtime.parse_note(path.read_text(), day)
        if parsed is None:
            continue
        parts = path.stem.split(" ", 2)
        topic = parts[2] if len(parts) > 2 else path.stem
        out.append((topic, *parsed))
    return out


def last_topic():
    """Return the topic of the newest session note, or None."""
    files = sorted(WORKLOG.glob("2*.md"))
    if not files:
        return None
    parts = files[-1].stem.split(" ", 2)
    return parts[2] if len(parts) > 2 else None


def ask_time(minutes: int, step: str = ""):
    """Ask for the clock time of the start. Return the datetime, BACK, or None.

    The time fields open with the end of the last session of the day, so
    the common backfill — 'it started when the last block ended' — is one
    return key. With no session today, they open with now, rounded down to
    15 minutes.
    """
    now = datetime.now()
    notes = day_notes(now.date())
    base = max((end for _, _, end in notes), default=None)
    if base is None or base > now:
        base = punchtime.round_down_quarter(now)
    h12, minute, ampm = punchtime.to_12h(base)

    if HUD.exists():
        args = [str(HUD), "time"]
        if step:
            args += ["--step", step]
        try:
            r = subprocess.run(
                args + ["Start time", str(h12), f"{minute:02d}",
                        ampm, str(minutes)],
                capture_output=True, text=True, timeout=300)
            # The a and the p keys set am/pm in this HUD, so escape is the
            # way back. The step before this one asks Now or a time.
            if r.returncode != 0:
                return BACK
            hh, mm = r.stdout.strip().split(":")
            return now.replace(hour=int(hh), minute=int(mm),
                               second=0, microsecond=0)
        except Exception as e:
            log.warning("the time HUD failed: %s", e)

    # The fallback for a machine with no HUD: one line, 24 hour form.
    text = ask_text_native("Start time (HH:MM, today):")
    if text is None:
        return None
    try:
        t = datetime.strptime(text.strip(), "%H:%M")
    except ValueError:
        notify(f"Not a time: {text}")
        return None
    start_at = now.replace(hour=t.hour, minute=t.minute,
                           second=0, microsecond=0)
    if start_at > now:
        notify("The start must lie in the past.")
        return None
    return start_at


def ask_start(minutes: int, step: str = ""):
    """Ask when the session started. Return the datetime, BACK, or None.

    This is step 3. A time that the user leaves with escape brings back
    the Now question of the same step, and the p key there goes to the
    timebox of step 2.
    """
    while True:
        when = choose("Start when?", ["Now", "Set a time…"], 0, step, True)
        if when is None or when is BACK:
            return when
        if when == "Now":
            return datetime.now()
        start_at = ask_time(minutes, step)
        if start_at is BACK:
            continue
        return start_at


def start_live(topic: str, minutes: int, start_at: datetime,
               focus: str = "") -> None:
    if open_state() is not None:
        raise SystemExit("A session is already open. Run 'punch reset' first.")

    planned_end = start_at + timedelta(minutes=minutes)
    kind, remaining = punchtime.classify(start_at, minutes, datetime.now())
    # The caller routes retro starts to log_retro, so this is a guard.
    if kind != "live":
        raise SystemExit("The timebox already ended. This is a retro session.")

    # A timer of the same length that still runs blocks the start, so it
    # goes first.
    stale = stale_timer(remaining, timers.load())
    if stale is not None:
        _stop_stale_timer(stale)
    before = {t["id"] for t in timers.active(timers.load())}
    _start_timer(remaining)
    log.info("timer requested: topic=%r minutes=%d start=%s",
             topic, remaining, start_at.isoformat())

    # The wait for the Clock.app plist and the Calendar event take seconds.
    # A pending state file lets the pill show at once. check() skips a
    # pending session, because it has no timer to judge yet.
    session = {
        "topic": topic,
        "focus": focus,
        "start": start_at.isoformat(),
        "planned_end": planned_end.isoformat(),
        "minutes": minutes,
        "timer_id": "",
        "event_uid": "",
        "source": "live",
    }
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps({**session, "pending": True}, indent=2))
    # A new session always shows its pill, even when the last one was hidden.
    PILL_FLAG.unlink(missing_ok=True)
    start_pill()

    # The timer above is already running. Everything past this point can
    # still fail, so a failure here must be loud — a silent one leaves the
    # timer running with no session to log it.
    try:
        # Give the Shortcuts app time to write the plist.
        timer_id = _wait_for_timer(before, START_TRIES)
        if not timer_id and ask_timer_reset(topic):
            timer_id = restart_timer(remaining)
        if not timer_id:
            raise RuntimeError(
                "no new timer showed up in the Clock.app plist. A timer of "
                "the same length may still run, or the shortcut "
                f"'{SHORTCUT}' is missing on this machine.")

        uid = cal.create_event(topic, start_at, planned_end)
    except Exception as e:
        # The pending state goes away, so the pill quits and no ghost
        # session waits for a check() that can never end it.
        STATE.unlink(missing_ok=True)
        log.error("session tracking failed after the timer started: %s",
                  e, exc_info=True)
        notify(f"{topic} timer is running, but session logging failed — "
               "see the log")
        raise

    STATE.write_text(json.dumps({
        **session, "timer_id": timer_id, "event_uid": uid,
    }, indent=2))
    log.info("session started: topic=%r minutes=%d timer_id=%s event_uid=%s",
             topic, minutes, timer_id, uid)
    notify(f"{topic} — timer running, ends {planned_end:%H:%M}")


def start_pill() -> None:
    """Start the pill for the open session. A pill that runs is replaced.

    The pill quits by itself when the session closes, so there is no
    stop call. A machine with no HUD binary has no pill.
    """
    if not HUD.exists():
        return
    subprocess.run(["pkill", "-f", "timer-hud pill"], capture_output=True)
    try:
        subprocess.Popen([str(HUD), "pill"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except Exception as e:
        log.warning("the pill failed to start: %s", e)


def toggle_pill() -> None:
    """Hide the pill, or show it. A show restarts the pill if it has quit."""
    if PILL_FLAG.exists():
        PILL_FLAG.unlink()
        log.info("pill shown")
        alive = subprocess.run(["pgrep", "-f", "timer-hud pill"],
                               capture_output=True)
        if alive.returncode != 0:
            start_pill()
    else:
        PILL_FLAG.parent.mkdir(parents=True, exist_ok=True)
        PILL_FLAG.touch()
        log.info("pill hidden")


def log_retro(topic: str, minutes: int, start_at: datetime,
              focus: str = "") -> None:
    """Record a session that already ended. No timer, no state file."""
    end_at = start_at + timedelta(minutes=minutes)
    conflict = punchtime.find_overlap(start_at, end_at,
                                      day_notes(start_at.date()))

    try:
        cal.create_event(topic, start_at, end_at)
    except Exception as e:
        log.warning("calendar event failed for the retro session: %s", e)

    score = ask_distraction(f"{topic} — {start_at:%H:%M}–{end_at:%H:%M} · retro")
    s = {"topic": topic, "focus": focus, "start": start_at.isoformat(),
         "source": "retro"}
    finish(s, "completed", end_at, score)

    if conflict:
        # finish() shows its own toast for 2.5 seconds. Wait it out, or the
        # overlap warning lands under it and is never seen.
        time.sleep(2.6)
        notify(f"overlaps {conflict}")


def read_topics() -> list[str]:
    """Return the topics, with the frontmatter and blank lines removed."""
    lines = TOPICS.read_text().splitlines()
    out, fences = [], 0
    for line in lines:
        if line.strip() == "---" and fences < 2:
            fences += 1
            continue
        if fences < 2 or not line.strip():
            continue
        out.append(line.strip())
    return out


def parse_pick(out: str, options: list[str]):
    """Read the chosen option from the HUD.

    The HUD prints the index of the option. It prints skip when the user
    cancels, and timeout when nobody answers. Both give no choice, because
    a session must never start on its own. It prints back when the user
    presses the p key, which asks for the step before this one. It prints
    resync when the user holds control and presses r.
    """
    if out.strip() == "back":
        return BACK
    if out.strip() == "resync":
        return RESYNC
    try:
        index = int(out.strip())
    except ValueError:
        return None
    return options[index] if 0 <= index < len(options) else None


def choose_hud(prompt: str, options: list[str], select: int = 0,
               step: str = "", back: bool = False, search: bool = False,
               ctrl_key: str = ""):
    """Show the HUD list picker. Return the choice, BACK, or None."""
    args = [str(HUD), "pick", "--select", str(select)]
    if step:
        args += ["--step", step]
    if back:
        args.append("--back")
    if search:
        args.append("--search")
    if ctrl_key:
        args += ["--ctrl-key", ctrl_key]
    r = subprocess.run(args + [prompt, *options],
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise RuntimeError(f"the HUD failed: {r.stderr.strip()}")
    return parse_pick(r.stdout, options)


def choose(prompt: str, options: list[str], select: int = 0,
           step: str = "", back: bool = False, search: bool = False,
           ctrl_key: str = ""):
    """Ask the user to choose one option.

    The HUD answers on one key press. With search on, the letter keys
    narrow the list before the pick. A machine with no HUD binary falls
    back to the native picker, which has no step keys, no search, and no
    control keys. There the step label goes into the prompt and a cancel
    ends the flow.
    """
    if HUD.exists():
        try:
            return choose_hud(prompt, options, select, step, back, search,
                              ctrl_key)
        except Exception as e:
            log.warning("the pick HUD failed: %s", e)
    return choose_native(f"{step} — {prompt}" if step else prompt, options)


def choose_native(prompt: str, options: list[str]):
    """Show a native list picker. Return the choice, or None on cancel."""
    safe = [o.replace("\\", "").replace('"', "") for o in options]
    lst = ", ".join(f'"{o}"' for o in safe)
    script = ('tell application "System Events"\n'
              'activate\n'
              f'choose from list {{{lst}}} with title "Punch" '
              f'with prompt "{prompt}" default items {{"{safe[0]}"}}\n'
              'end tell')
    r = subprocess.run(["osascript", "-e", script],
                       capture_output=True, text=True)
    out = r.stdout.strip()
    if r.returncode != 0 or out == "false":
        return None
    return out


def ask_text_native(prompt: str):
    """Show a one-line text dialog. Return the text, or None on cancel."""
    script = ('tell application "System Events"\n'
              'activate\n'
              f'display dialog "{prompt}" default answer "" '
              'with title "Punch"\n'
              'end tell')
    r = subprocess.run(["osascript", "-e", script],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return r.stdout.strip().split("text returned:")[-1].strip() or None


def ask_text(prompt: str, digits: bool = False, step: str = "",
             back: bool = False, allow_empty: bool = False):
    """Ask for one line of text. Return the text, BACK, or None.

    The digits variant refuses every key that is not a digit, so a custom
    timebox can no longer abort the flow on a value like '9o'. With back
    on, escape returns BACK, so the prompt of the step comes back instead
    of the flow ending. With allow_empty on, the return key on a blank
    line returns an empty string instead of None.
    """
    if HUD.exists():
        args = [str(HUD), "digits" if digits else "text"]
        if step:
            args += ["--step", step]
        if allow_empty:
            args.append("--allow-empty")
        try:
            r = subprocess.run(args + [prompt],
                               capture_output=True, text=True, timeout=300)
            if r.returncode == 0:
                text = r.stdout.strip()
                return text if allow_empty else (text or None)
            return BACK if back else None
        except Exception as e:
            log.warning("the text HUD failed: %s", e)
    text = ask_text_native(f"{step} — {prompt}" if step else prompt)
    if text is None and back:
        return BACK
    return text


def start_resync() -> bool:
    """Confirm a resync, then start it as its own process.

    Return True when the resync runs. A refused resync returns False, so
    the caller brings back the list of topics instead of ending the flow.

    A resync takes minutes, so punch never waits for it. The new process
    shows a toast when it ends. The confirm opens on no, because the row
    sits in the same list that the search narrows.
    """
    if choose("Resync this machine?", ["no", "yes"]) != "yes":
        return False
    try:
        subprocess.Popen([sys.executable, str(RESYNC_SCRIPT)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
        log.info("resync started")
        return True
    except Exception as e:
        log.warning("the resync failed to start: %s", e)
        notify("resync failed to start")
        return False


def ask_topic(current=None):
    """Ask which topic to punch. Return the topic, or None on cancel.

    This is step 1, so there is no step to go back to and the p key stays
    off. The pick has search on, so the letter keys narrow the topics and
    one digit takes the match. A new topic that the user leaves with
    escape brings back the list of topics.

    Control and r start a resync instead of a session. A resync that
    runs ends the flow, because a resync is not a punch. A refused
    resync brings back the list of topics.
    """
    step = step_label(1, [])
    while True:
        options = read_topics() + [OTHER]
        recent = current or last_topic()
        select = options.index(recent) if recent in options else 0
        topic = choose("What are you punching?", options, select, step,
                       search=True, ctrl_key=RESYNC_KEY)
        if topic is None or topic is BACK:
            return None
        if topic is RESYNC:
            if start_resync():
                return None
            continue
        if topic != OTHER:
            return topic

        new = ask_text("New topic:", step=step, back=True)
        if new is BACK:
            continue
        if new is None:
            return None
        with TOPICS.open("a") as f:
            if TOPICS.read_bytes()[-1:] not in (b"\n", b""):
                f.write("\n")
            f.write(new + "\n")
        return new


def ask_minutes(current, step: str):
    """Ask for the timebox in minutes. Return the number, BACK, or None.

    A custom value that the user leaves with escape brings back the list
    of presets, and so does a value that is not a number.
    """
    options = PRESETS + ["custom…"]
    select = options.index(current) if current in options else 0
    while True:
        minutes = choose("For how long?", options, select, step, True)
        if minutes is None or minutes is BACK:
            return minutes
        if minutes == "custom…":
            minutes = ask_text("Minutes:", digits=True, step=step, back=True)
            if minutes is BACK:
                continue
            if minutes is None:
                return None
        try:
            return str(int(minutes))
        except ValueError:
            notify(f"Not a number: {minutes}")


def ask_focus(step: str = ""):
    """Ask what the session is for. Return the text, BACK, or "".

    This step is optional. The return key on a blank line skips it, and an
    empty answer means the pill shows the topic. Escape goes back a step.
    """
    text = ask_text("What will you work on? (return skips)", step=step,
                    back=True, allow_empty=True)
    return "" if text is None else text


def start_interactive() -> None:
    """Walk the four steps of a start, then start the session.

    Every prompt names its step, and the n and the p keys walk the flow
    forward and back. A wrong topic no longer means starting again: the
    step keeps the answer that stood before, so p and n cost two keys.
    """
    # An open session blocks a new one. Offer to close it instead of only
    # refusing, so a session that nobody ended is never a dead end.
    if open_state() is not None and reset() == "keep":
        return

    topic, focus, minutes, start_at = None, "", None, None
    step = 1
    while step <= STEPS:
        if step == 1:
            answer = ask_topic(topic)
        elif step == 2:
            answer = ask_focus(step_label(2, [topic]))
        elif step == 3:
            answer = ask_minutes(minutes, step_label(3, [topic, focus]))
        else:
            answer = ask_start(int(minutes),
                               step_label(4, [topic, focus, f"{minutes} min"]))
        if answer is None:
            return
        # A step that the user leaves backwards keeps the answer that
        # stood before, so the step opens on the same item again.
        if answer is not BACK:
            if step == 1:
                topic = answer
            elif step == 2:
                focus = answer
            elif step == 3:
                minutes = answer
            else:
                start_at = answer
        step = advance(step, answer)

    m = int(minutes)
    kind, _ = punchtime.classify(start_at, m, datetime.now())
    if kind == "live":
        # Ask before the timer starts. The start waits for the Clock.app
        # plist, so a prompt after it comes too late.
        offer_moodist()
        start_live(topic, m, start_at, focus)
    else:
        log_retro(topic, m, start_at, focus)


def offer_moodist() -> None:
    """Ask to open Moodist, and open it on the return key.

    Escape, a timeout, and Skip leave it closed. The page is only a
    help, so a failure here is logged and the session starts anyway.
    """
    if choose("Play ambient sound?", [MOODIST_OPEN, "Skip"]) != MOODIST_OPEN:
        return
    try:
        subprocess.run(["open", MOODIST_URL], check=True)
    except Exception as e:
        log.warning("failed to open Moodist: %s", e)


def notify(text: str) -> None:
    """Show a small overlay through the karabiner HUD binary.

    Notification Center drops both the osascript and the Keyboard
    Maestro notifications on this machine, so the HUD shows a toast
    instead. Failures never block the session.
    """
    try:
        subprocess.Popen([str(HUD), "toast", text],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def idle_seconds() -> float:
    """Return the seconds since the last key press or mouse move."""
    out = subprocess.run(
        ["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "HIDIdleTime" in line:
            return int(line.split("=")[-1].strip()) / 1_000_000_000
    return 0.0


def parse_distraction(out: str):
    """Read the score from the result of the distraction dialog.

    Return None when the answer is not a score from 1 to 10. A dialog that
    closed itself takes the default score, because an empty desk means the
    session ran without the user in it.
    """
    if "gave up:true" in out:
        return AWAY_DISTRACTION
    text = out.split("text returned:")[-1].split(", gave up:")[0].strip()
    try:
        value = int(text)
    except ValueError:
        return None
    return value if 1 <= value <= 10 else None


def parse_score(out: str):
    """Read the score from the HUD.

    The HUD prints the score, skip, or timeout. Return None when there is
    no score, and the default score when nobody answered.
    """
    text = out.strip()
    if text == "timeout":
        return AWAY_DISTRACTION
    try:
        value = int(text)
    except ValueError:
        return None
    return value if 1 <= value <= 10 else None


def ask_distraction_dialog(topic: str):
    """Ask for the score in a text dialog. This is the fallback for a
    machine that has no HUD binary."""
    script = (
        'tell application "System Events"\n'
        'activate\n'
        f'display dialog "How distracted were you during {topic}?\\n'
        '1 is no interruptions. 10 is never more than 15 clear minutes." '
        'default answer "" with title "Punch" '
        f'giving up after {DIALOG_TIMEOUT}\n'
        'end tell')
    r = subprocess.run(["osascript", "-e", script],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return parse_distraction(r.stdout.strip())


def ask_distraction(topic: str):
    """Ask for the score. Return None if the user skips the prompt.

    The HUD answers on one key press, so the user never needs the mouse.
    """
    if not HUD.exists():
        return ask_distraction_dialog(topic)
    try:
        r = subprocess.run([str(HUD), "score", topic, str(DIALOG_TIMEOUT)],
                           capture_output=True, text=True,
                           timeout=DIALOG_TIMEOUT + 30)
    except Exception as e:
        log.warning("the score HUD failed: %s", e)
        return ask_distraction_dialog(topic)
    if r.returncode != 0:
        return ask_distraction_dialog(topic)
    return parse_score(r.stdout)


def ask_open_session(s: dict) -> str:
    """Ask what to do with a session that is still open.

    The return key takes 'End & log', which is the safe and common answer.
    Escape and a timeout return keep, so a closed prompt never destroys an
    open session. The pill option shows or hides the pill, and it returns
    pill, so the caller keeps the session open.
    """
    start_at = datetime.fromisoformat(s["start"])
    prompt = f"{s['topic']} is still open — {start_at:%H:%M}, {s['minutes']} min"
    pill = PILL_SHOW if PILL_FLAG.exists() else PILL_HIDE
    if s.get("pending"):
        # The start still runs and writes the final state in a moment. An
        # end or a discard here would leave a ghost, so the pill toggle is
        # the only action. Return is Keep, so a stray press does no harm.
        prompt = f"{s['topic']} is starting — {s['minutes']} min"
        choice = choose(prompt, ["Keep it", pill])
    else:
        choice = choose(prompt, ["End & log", "Keep it", "Discard", pill])
    return {"End & log": "end", "Discard": "discard",
            PILL_HIDE: "pill", PILL_SHOW: "pill"}.get(choice, "keep")


def finish(s: dict, status: str, end_at: datetime, distraction) -> None:
    """Write the note, close the calendar event, and tell the user.

    Every failure is reported and then passed over. The state file is gone
    by this point, so a failure here must not stop the rest of the work.
    """
    start_at = datetime.fromisoformat(s["start"])
    path, body = note.build_note(s["topic"], start_at, end_at, status,
                                 distraction, s.get("source", "live"),
                                 s.get("focus", ""))

    # Show the toast first. The Calendar and the Obsidian calls below wait
    # on other apps, and the user should not wait with them.
    hours = round((end_at - start_at).total_seconds() / 3600, 2)
    notify(f"{s['topic']} {status} — {hours} h logged")

    if status == "cancelled":
        # A cancelled session leaves its timer running. That timer would
        # block the next start of the same length, so it goes first.
        stop_session_timer(s)

    if status == "cancelled" and s.get("event_uid"):
        marked = time.monotonic()
        try:
            result = cal.mark_cancelled(s["event_uid"], s["topic"])
            if result == "missing":
                log.warning("calendar event %s not found", s["event_uid"])
        except Exception as e:
            log.warning("mark_cancelled failed: %s", e)
        log.info("calendar marked in %.1fs", time.monotonic() - marked)

    opened = time.monotonic()
    try:
        subprocess.run(["open", note.adv_uri(path, body)], check=True)
    except Exception as e:
        log.warning("failed to open note: %s", e)
    log.info("session %s: topic=%r hours=%s note_open=%.1fs",
             status, s["topic"], hours, time.monotonic() - opened)


def reset() -> str:
    """Deal with a session that is still open.

    Return end, discard, or keep. The state file is gone after end and
    after discard, so the caller can start a new session.
    """
    found = open_state()
    if found is None:
        notify("No session is open.")
        return "keep"

    path, s = found
    choice = ask_open_session(s)
    if choice == "keep":
        return "keep"
    if choice == "pill":
        toggle_pill()
        return "keep"

    path.unlink()
    if choice == "discard":
        # The timer would block the next start of the same length.
        stop_session_timer(s)
        log.info("session discarded: topic=%r", s["topic"])
        notify(f"{s['topic']} discarded — nothing logged")
        return "discard"

    planned_end = datetime.fromisoformat(s["planned_end"])
    finish(s, "cancelled", min(datetime.now(), planned_end), None)
    return "end"


def check() -> None:
    if not STATE.exists():
        return

    # Atomically claim the session so a second check() run (e.g. launchd
    # firing again while a distraction dialog is still open) skips it
    # instead of opening a second dialog and writing a duplicate note.
    claimed = CLAIM
    try:
        STATE.rename(claimed)
    except FileNotFoundError:
        return

    try:
        s = json.loads(claimed.read_text())
        if s.get("pending"):
            # The start still waits for the timer. Nothing to judge yet.
            # The start may have written the final state while this claim
            # stood, and that state must win over the pending one.
            if STATE.exists():
                claimed.unlink()
            else:
                claimed.rename(STATE)
            return
        planned_end = datetime.fromisoformat(s["planned_end"])
        now = datetime.now()

        timer = next((t for t in timers.load() if t["id"] == s["timer_id"]), None)
        if timer is not None and timer["fired_date"] is not None:
            # The plist holds an aware date. Compare in the local naive form.
            timer = {**timer,
                     "fired_date": timer["fired_date"].astimezone().replace(tzinfo=None)}

        status, end_at = outcome.classify(timer, planned_end, now, idle_seconds())
        if status == "running":
            # Not actually done yet. Release the claim for the next run.
            claimed.rename(STATE)
            return

        # The times here show where a slow end spends its seconds.
        fired = timer["fired_date"] if timer else None
        log.info("check: status=%s fired=%s wait_before_score=%.1fs",
                 status, fired, (datetime.now() - fired).total_seconds()
                 if fired else -1)
        asked = time.monotonic()
        distraction = ask_distraction(s["topic"]) if status == "completed" else None
        log.info("check: score=%s answered_in=%.1fs",
                 distraction, time.monotonic() - asked)
    except Exception:
        # Something failed mid-way, before any side effect ran. Put the
        # state file back so the next minute's check() retries.
        log.error("check failed, will retry next run", exc_info=True)
        claimed.rename(STATE)
        raise

    # From here on, side effects begin. The claim must not go back to
    # STATE, or a failure here would cause a retry and a duplicate note.
    claimed.unlink()
    finish(s, status, end_at, distraction)


if __name__ == "__main__":
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=LOG_PATH, level=logging.INFO,
                         format="%(asctime)s %(levelname)s %(message)s")

    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("start")
    s.add_argument("--topic", required=True)
    s.add_argument("--minutes", type=int, required=True)
    sub.add_parser("start-interactive")
    sub.add_parser("check")
    sub.add_parser("reset")
    a = p.parse_args()
    if a.cmd == "start":
        start_live(a.topic, a.minutes, datetime.now())
    elif a.cmd == "start-interactive":
        start_interactive()
    elif a.cmd == "check":
        check()
    elif a.cmd == "reset":
        print(reset())
