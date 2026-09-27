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

# The interactive start asks three questions: the topic, the timebox, and
# the start time. The user walks the steps with the n and the p keys.
STEPS = 3


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


def _start_timer(minutes: int) -> None:
    url = (f"shortcuts://run-shortcut?name={SHORTCUT.replace(' ', '%20')}"
           f"&input=text&text={minutes}")
    subprocess.run(["open", url], check=True)


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


def start_live(topic: str, minutes: int, start_at: datetime) -> None:
    if open_state() is not None:
        raise SystemExit("A session is already open. Run 'punch reset' first.")

    planned_end = start_at + timedelta(minutes=minutes)
    kind, remaining = punchtime.classify(start_at, minutes, datetime.now())
    # The caller routes retro starts to log_retro, so this is a guard.
    if kind != "live":
        raise SystemExit("The timebox already ended. This is a retro session.")

    before = {t["id"] for t in timers.active(timers.load())}
    _start_timer(remaining)
    log.info("timer requested: topic=%r minutes=%d start=%s",
             topic, remaining, start_at.isoformat())

    # The timer above is already running. Everything past this point can
    # still fail, so a failure here must be loud — a silent one leaves the
    # timer running with no session to log it.
    try:
        # Give the Shortcuts app time to write the plist.
        timer_id = ""
        for _ in range(20):
            time.sleep(1)
            new = [t for t in timers.active(timers.load()) if t["id"] not in before]
            if new:
                timer_id = new[0]["id"]
                break
        if not timer_id:
            raise RuntimeError(
                "the timer never showed up in the Clock.app plist. Check "
                f"that the shortcut '{SHORTCUT}' exists on this machine.")

        uid = cal.create_event(topic, start_at, planned_end)
    except Exception as e:
        log.error("session tracking failed after the timer started: %s",
                  e, exc_info=True)
        notify(f"{topic} timer is running, but session logging failed — "
               "see the log")
        raise

    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps({
        "topic": topic,
        "start": start_at.isoformat(),
        "planned_end": planned_end.isoformat(),
        "minutes": minutes,
        "timer_id": timer_id,
        "event_uid": uid,
        "source": "live",
    }, indent=2))
    log.info("session started: topic=%r minutes=%d timer_id=%s event_uid=%s",
             topic, minutes, timer_id, uid)
    notify(f"{topic} — timer running, ends {planned_end:%H:%M}")


def log_retro(topic: str, minutes: int, start_at: datetime) -> None:
    """Record a session that already ended. No timer, no state file."""
    end_at = start_at + timedelta(minutes=minutes)
    conflict = punchtime.find_overlap(start_at, end_at,
                                      day_notes(start_at.date()))

    try:
        cal.create_event(topic, start_at, end_at)
    except Exception as e:
        log.warning("calendar event failed for the retro session: %s", e)

    score = ask_distraction(f"{topic} — {start_at:%H:%M}–{end_at:%H:%M} · retro")
    s = {"topic": topic, "start": start_at.isoformat(), "source": "retro"}
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
             back: bool = False):
    """Ask for one line of text. Return the text, BACK, or None.

    The digits variant refuses every key that is not a digit, so a custom
    timebox can no longer abort the flow on a value like '9o'. With back
    on, escape returns BACK, so the prompt of the step comes back instead
    of the flow ending.
    """
    if HUD.exists():
        args = [str(HUD), "digits" if digits else "text"]
        if step:
            args += ["--step", step]
        try:
            r = subprocess.run(args + [prompt],
                               capture_output=True, text=True, timeout=300)
            if r.returncode == 0:
                return r.stdout.strip() or None
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


def start_interactive() -> None:
    """Walk the three steps of a start, then start the session.

    Every prompt names its step, and the n and the p keys walk the flow
    forward and back. A wrong topic no longer means starting again: the
    step keeps the answer that stood before, so p and n cost two keys.
    """
    # An open session blocks a new one. Offer to close it instead of only
    # refusing, so a session that nobody ended is never a dead end.
    if open_state() is not None and reset() == "keep":
        return

    topic, minutes, start_at = None, None, None
    step = 1
    while step <= STEPS:
        if step == 1:
            answer = ask_topic(topic)
        elif step == 2:
            answer = ask_minutes(minutes, step_label(2, [topic]))
        else:
            answer = ask_start(int(minutes),
                               step_label(3, [topic, f"{minutes} min"]))
        if answer is None:
            return
        # A step that the user leaves backwards keeps the answer that
        # stood before, so the step opens on the same item again.
        if answer is not BACK:
            if step == 1:
                topic = answer
            elif step == 2:
                minutes = answer
            else:
                start_at = answer
        step = advance(step, answer)

    m = int(minutes)
    kind, _ = punchtime.classify(start_at, m, datetime.now())
    if kind == "live":
        start_live(topic, m, start_at)
        offer_moodist()
    else:
        log_retro(topic, m, start_at)


def offer_moodist() -> None:
    """Ask to open Moodist, and open it on the return key.

    Escape, a timeout, and Skip leave it closed. The session is already
    running, so a failure here is logged and passed over.
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
    open session.
    """
    start_at = datetime.fromisoformat(s["start"])
    prompt = f"{s['topic']} is still open — {start_at:%H:%M}, {s['minutes']} min"
    choice = choose(prompt, ["End & log", "Keep it", "Discard"])
    return {"End & log": "end", "Discard": "discard"}.get(choice, "keep")


def finish(s: dict, status: str, end_at: datetime, distraction) -> None:
    """Write the note, close the calendar event, and tell the user.

    Every failure is reported and then passed over. The state file is gone
    by this point, so a failure here must not stop the rest of the work.
    """
    start_at = datetime.fromisoformat(s["start"])
    path, body = note.build_note(s["topic"], start_at, end_at, status,
                                 distraction, s.get("source", "live"))

    if status == "cancelled":
        try:
            result = cal.mark_cancelled(s["event_uid"], s["topic"])
            if result == "missing":
                log.warning("calendar event %s not found", s["event_uid"])
        except Exception as e:
            log.warning("mark_cancelled failed: %s", e)

    try:
        subprocess.run(["open", note.adv_uri(path, body)], check=True)
    except Exception as e:
        log.warning("failed to open note: %s", e)

    hours = round((end_at - start_at).total_seconds() / 3600, 2)
    log.info("session %s: topic=%r hours=%s", status, s["topic"], hours)
    notify(f"{s['topic']} {status} — {hours} h logged")


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

    path.unlink()
    if choice == "discard":
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

        distraction = ask_distraction(s["topic"]) if status == "completed" else None
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
