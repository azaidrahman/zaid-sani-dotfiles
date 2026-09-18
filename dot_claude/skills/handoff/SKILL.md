---
name: handoff
description: Use when a session ends with trailing work — you just offered to dig into something ("want me to look at that?"), the user says "file that and keep going", "hand this off", "continue in a new window", "pick up where we left off", or names a leftover thread from the board. Turns one loose thread into a Jira ticket, a branch and worktree, and a fresh tmux window running Claude with a written brief of what this session already established.
---

# Hand off a trailing thread

A session ends with more open threads than it closes. The next window usually starts cold: it re-reads the same logs, re-derives the same theory, and asks the user to repeat what they said an hour ago. A **handoff** carries the session's findings forward in writing, so the new window opens warm.

You write the brief. The other skills do the rest:

- [[writing-tickets]] — the ticket title and Why / What / Done-when body.
- [[start-ticket-worktree]] — branch `<type>/<KEY>-<slug>` and worktree `.worktrees/<KEY>-<slug>`.
- `handoff.sh` (next to this file) — the tmux window and the Claude boot.

Not [[wrap-session]]. That one closes out *everything* the session touched. A handoff carries *one* thread forward and leaves the rest alone.

## Step 1 — Name the thread

List the trailing threads from **this conversation only** — things you offered to do, questions you raised and left open, items the user parked. Do not scan the board or Jira for more; unrelated open tickets are not trailing work.

Rank them: the thread you most recently offered to pursue is the default pick. Put it and up to three others in one `AskUserQuestion`, each labelled with what the next window would actually do. If the user already named the thread, skip the question.

**Done when:** you can state the thread in one sentence, and the user has confirmed it.

## Step 2 — Harvest the session

Go back through the conversation and pull out what the next window would otherwise have to rediscover. Read the transcript for this — do not reconstruct it from the repo.

Harvest each of these, or write "none" for it:

| Field | What goes in it |
|---|---|
| **Established** | Facts this session confirmed, each with its evidence — the command that showed it, the file and line, the log line. |
| **Theory** | The leading explanation, and the rival ones not yet ruled out. |
| **Ruled out** | Dead ends, so the next window does not re-walk them. |
| **Touched** | Files changed, commands that mutated anything, resources applied. |
| **Next step** | The single first action for the new window. |
| **Verification** | How the new window can confirm the thread is closed — a test to run or a behavior to check. |

**Done when:** every row is filled, and every claim in **Established** carries its evidence. A claim without evidence is a theory — move it.

## Step 3 — File the ticket

Invoke [[writing-tickets]] and create the issue. Feed it the harvest: **Theory** and **Established** are the Why, **Next step** is the What, and the observable state that ends the thread is the Done-when.

Ask the user to confirm the project and the title before you create it.

**Done when:** you hold a real `KEY` returned by Jira.

## Step 4 — Start the branch

Invoke [[start-ticket-worktree]] with that `KEY`. Take its Mode A path — one ticket, no `--session` — because Step 5 opens a **window** in the session the user is already sitting in, not a detached session to attach to.

Skip its `EnterWorktree` step. This session must stay in the current checkout, because Step 5 opens a separate window for the new work. The window starts in the worktree by itself.

Keep the worktree path and the branch name it reports. Both go in the brief.

**Done when:** the script exits `0` and you hold an absolute worktree path.

## Step 5 — Write the brief

Write the harvest to `~/.claude/handoffs/<KEY>.md`. Create the directory if it is absent. This path is outside every repository, so the brief can never land in a commit.

Use this shape exactly:

```markdown
# <KEY> — <ticket title>

Ticket   : <KEY> <jira url>
Branch   : <type>/<KEY>-<slug>
Worktree : /abs/path/.worktrees/<KEY>-<slug>
Handed off: <YYYY-MM-DD> from a session on <what that session was doing>

## Next step
<the single first action>

## Established
- <fact> — <evidence: command, file:line, or log line>

## Theory
<leading explanation; then the rivals still open>

## Ruled out
- <dead end> — <why>

## Touched
- <file or resource> — <what changed>

## Verification
<how to confirm the thread is closed — the test to run or the behavior to check>
```

**Done when:** the file exists and someone who did not attend this session could take the **Next step** from it alone.

## Step 6 — Open the window

```bash
SH=~/.claude/skills/handoff/handoff.sh
"$SH" "$KEY" "<worktree>" ~/.claude/handoffs/"$KEY".md "<KEY> <short label>"
```

The script opens a tmux window rooted in the worktree and starts `claude` with a prompt that points at the brief. It selects an existing window instead if one already carries the key.

| stdout / exit | Means | Do |
|---|---|---|
| `window: created` | New window is running Claude on the brief. | Report it. |
| `window: reused` | A window for this key was already open; it is now selected. | Say so — the brief is on disk either way. |
| `no-tmux` (exit 3) | No tmux, or you are outside it. | Report the brief path and the `cd` command. The handoff still holds. |

**Done when:** the window is open, or you have told the user exactly how to resume by hand.

## Step 7 — Report

Four lines, then stop. Stay in the current window — the user drives the switch.

```
Handed off: GTI-631 — "obs: HTTPRoutes stay OutOfSync under selfHeal"
Branch    : fix/GTI-631-httproutes-outofsync
Brief     : ~/.claude/handoffs/GTI-631.md
Window    : GTI-631 httproutes (created)
```

If other threads were on the board, name them in one line so they stay visible. Do not hand them off unasked.

## Common mistakes

| Mistake | Fix |
|---|---|
| A brief that only restates the ticket | The ticket says what to do; the brief says what is already known. If they read the same, you skipped Step 2. |
| Claims in **Established** with no evidence | Move them to **Theory**. The next window trusts this file and will not re-verify it. |
| Rebuilding the harvest from the repo | The value is the reasoning, and that lives only in the transcript. Read the transcript. |
| Writing the brief into the worktree | Repo files get committed. Briefs live in `~/.claude/handoffs/`. |
| Hand-rolling `tmux new-window` + `send-keys` | Call `handoff.sh` — it roots the window with `-c`, sanitizes the label, and reuses an open window. |
| Passing `--session` to start-ticket-worktree | That makes a detached session. This skill wants a window in the session the user is in. |
| Handing off every open thread | One thread per run. Several threads at once is [[wrap-session]]. |
| Switching the user to the new window | Open it and report. The user chooses when to move. |
