# Punch

Punch records blocks of focused work. Each block has a topic, a start, and an
end. The tool writes a note in the Polaris vault and an event in Calendar.app.
A dashboard reads the notes and totals the hours.

## Language

**Session**:
One block of focused work. A session has a topic, a start, and an end.
_Avoid_: study session, block, entry, task

**Topic**:
The subject of a session. The user picks it from `Topics.md`.
_Avoid_: project, category, tag, label

**Focus**:
The short text that says what the user will work on in a session. It is
optional. A session with no focus shows its topic instead.
_Avoid_: title, goal, intent, description

**Timebox**:
The planned length of a session. The user picks it before the session starts.
Every session has one.
_Avoid_: duration, length, budget

**Live session**:
A session that a Clock.app timer tracks while it runs. The timer proves that
the session happened.
_Avoid_: real session, tracked session, active session

**Retro session**:
A session that the user records after it ended. No timer tracks it. The user
asserts the times.
_Avoid_: backfill, manual entry, past session

**Source**:
The field that separates a live session from a retro session. The value is
`live` or `retro`. A note with no `source` field is live.
_Avoid_: kind, type, origin

**Distraction**:
A score from 1 to 10 for a finished session. A score of 1 means no
interruptions. A score of 10 means never more than 15 clear minutes.
_Avoid_: focus score, quality, rating

**Status**:
How a session ended. The value is `completed` or `cancelled`.
_Avoid_: state, result, outcome

**Resync**:
The job that brings the machine back to the chezmoi source. It clears
the script state, so every chezmoi hook runs again. Step 1 offers it as
a row. It is not a session, and it is not the `reset` of an open
session.
_Avoid_: reset, sync, update, repair

**HUD**:
The Swift program that shows every prompt. It reads one key press. The user
never needs the mouse.
_Avoid_: dialog, popup, overlay, panel

**Stale timer**:
A Clock.app timer that still runs after its session closed. Clock.app keeps
one timer per length, so a stale timer blocks the next start of the same
length. The close stops its timer, and the start stops a stale timer before
it starts a new one.
_Avoid_: ghost timer, orphan timer, leftover timer

**Pill**:
A small floating window. It shows the focus of the live session, or the
topic, and the time left in the timebox. The user hides it or shows it from
the punch shortcut while a session is open.
_Avoid_: badge, widget, overlay, timer window

## Notes on the model

- The Clock.app timer is a way to track a live session. It is not the identity
  of a session. The first design said the opposite. See ADR 0001.
- A retro session is still a session. The `source` field keeps the data honest,
  so the dashboard can leave retro sessions out of a completion rate.
- Punch tracks focused work of any kind. Study and work are topics. The
  calendar is `Task Punch`. An older name, `Study`, is from the first design.
