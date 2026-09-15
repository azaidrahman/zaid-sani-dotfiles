---
name: task-sweep
description: Use when the user does not like the state of the board today - "my tasks are a mess", "clean up my tasks", "too much overdue", "sort out today", "what should I do today". Reads Jira and Todoist, then proposes one plan that re-decides the promoted set, catches drift between a ticket status and its workstream, and clears stale dates. The user approves once before any write.
---

# Tidy the board on demand

The board drifts in one direction. Dated work rolls past its date and goes red.
A ticket changes status in Jira and stays in the wrong workstream. Todoist then
shows noise instead of work.

This skill runs when the user asks for it. It is not scheduled, and it does not
run on a branch event. The user looks at Today, dislikes it, and asks.

**Read everything first. Write nothing until the user approves the plan.**

## Two clocks

The two systems measure different things. Keep them apart.

| Clock | Meaning | This skill |
|---|---|---|
| Jira `duedate` | The commitment. Other people read it. | Leave it alone. |
| Todoist due date | "I do this today." | Re-decide it each sweep. |

A stale Jira date is a missed commitment. It needs a conversation, not a silent
bump. Report it; do not change it.

## How the board works

Observed on 2026-09-15. `todoist-ticket-sync` describes the same board.

`Work` is an empty parent project. Three sub-projects hold the tickets:
`Infra Work`, `Team Requests`, and `Ops & Firefighting`. `Admin & Compliance`
and `Learning` hold the rest.

A top-level task is a **workstream**. Its subtasks are the tickets in that
stream. Every ticket subtask carries the label `gti` and starts with the key.

The board already runs a promotion convention. Follow it. Do not invent another.

| State | Shape |
|---|---|
| Parked | The subtask sits at `p4` with no due date. This is most tickets. |
| Promoted | The subtask carries a due date and `p2`. Use `p1` for a live break. |
| A review anchor | The workstream parent carries a date and repeats weekly. |

`Infra Work` has three sections. A workstream parent lives in one of them.

- `Now` holds the stream with the earliest start date.
- `Next` holds queued streams, in date order.
- `Blocked` holds tickets that wait on another person.

Most subtasks are parked. On 2026-09-15, 51 of 58 tasks in `Infra Work` were
parked subtasks. That is correct, not a mess. Do not promote in bulk.

## Which tool to use

Use the Todoist MCP tools (`mcp__todoist__*`) and the Atlassian MCP tools. If
either set is absent, tell the user and stop. Do not fall back to a CLI.

If Todoist returns a token error, tell the user to run `/mcp` and stop.

`get-overview` on a large project overflows the result limit. Pass a
`projectId` and read one project at a time.

## The sweep

Run steps 1 to 5 as read-only work. Then present the plan.

### 1. Read both systems

- Jira: the open tickets that the user is assigned. Record the key, the status,
  and the due date.
- Todoist: each project under `Work`, one at a time. Record the workstreams,
  their sections, the subtasks, and which subtasks are promoted.

### 2. Reconcile status

Compare each ticket key against its Todoist subtask.

- If the ticket is Done in Jira, propose to complete the subtask.
- If the subtask is complete and the ticket is open, propose the Jira
  transition. **First check for a branch that carries the key.** If a branch
  exists, `finish-branch` owns that transition. Leave it, and say so.
- If a ticket has no subtask, it is new since the last sync. Name it, and let
  `todoist-ticket-sync` add it. Do not add it here.

### 3. Find drift

A ticket drifts when its Jira status no longer matches its workstream.

| Jira status | Belongs under |
|---|---|
| In Progress | The in-flight workstream in `Ops & Firefighting`. |
| Blocked | The workstream for blocked work, in the `Blocked` section. |
| A live break | The incident workstream in `Ops & Firefighting`. |
| Anything else | Its build stream. Leave it. |

Discover the workstreams at run time. Do not hardcode their names.

If no workstream clearly fits, **leave the subtask alone**. List it under
"needs a decision". Never guess a destination.

> To move a subtask, set `parentId` and nothing else. Do not set `sectionId` or
> `projectId` on a subtask. Todoist reads either one as a move out of the
> parent, and the subtask lands loose in the section with no `parentId`.
>
> A new parent in another project takes the subtask with it. Todoist sets the
> project for you, and it keeps the labels and the date. Verified on 2026-09-15:
> GTI-756 moved from `Team Requests` to `Ops & Firefighting` on `parentId`
> alone. Tell the user that the project changes, because the plan does not
> otherwise show it.
>
> To move a whole stream, move the **workstream parent** between `Now`, `Next`,
> and `Blocked`. Its subtasks travel with it. Propose that as its own change.

### 4. Decide today

This is the main work. Ask what the user must do today, then propose a small
set.

- Promote each task in the set: a due date of today, and `p2`. Use `p1` for a
  live break.
- Demote a promoted task that the user is not working: clear the date, and
  return it to `p4`. It stays in its workstream.
- Leave a parked subtask parked unless the user names it.
- The user may pass a cap, for example `/task-sweep 3`. Honour it.

Handle an overdue review anchor separately. A workstream parent that repeats
weekly is a review, not a task. Ask whether the review happened. If it did,
complete the occurrence. Do not clear its date.

Pick the date tool by what the task already has. Verified on 2026-09-15.

| The task | The tool |
|---|---|
| Has a date. Move it. | `reschedule-tasks`. It keeps the repeat rule. |
| Has no date. Give it one. | `update-tasks` with `dueString`. |

`reschedule-tasks` fails on a task that has no date: "Rescheduling requires an
existing due date". A parked subtask has no date, so promote it with
`update-tasks`.

**Never send `dueString` to a recurring task.** It replaces the whole due
string and destroys the repeat rule. A review anchor repeats, so always move it
with `reschedule-tasks`.

One failed task fails the whole `reschedule-tasks` batch. Group the promotions
that need `update-tasks` into their own call.

### 5. Safety-net checks

Run these quietly. Report a finding only when there is one.

- A top-level task whose title starts with a key is a loose ticket. Propose a
  workstream for it.
- A loose Inbox task carrying `gti` belongs in a workstream. Propose one.
- A personal task is not your business. Leave it, and do not list it.

On 2026-09-15 all three checks were clean. Expect that. A finding here is the
exception, so say so plainly when one appears.

## The plan

Present one plan, grouped by action. Show the count in each group. Omit an
empty group.

```text
Today (2)
  GTI-756  promote: due today, p2
  GTI-748  promote: due today, p2

Demote (1)
  GTI-754  clear date, back to p4

Drift (1)
  GTI-756  In Progress in Jira  ->  move under "Finish in-flight work"

Review anchors (2)
  Provisioning queue   due yesterday, repeats Monday. Did the review happen?
  Waiting on others    due yesterday, repeats Monday. Did the review happen?

Complete (1)
  GTI-701  ticket is Done in Jira

Needs a decision (1)
  GTI-310  status "Scheduled Infra Development" fits no workstream

Left alone
  GTI-592  Jira due date 2026-07-30 is 47 days past. Renegotiate it.
```

Ask for approval with one `AskUserQuestion` call. Let the user veto single
lines. Write only what the user accepts.

## After the write

Re-read both systems. Report what changed, not what you intended to change. If
a write failed, say which one and why.

## Rules

- Propose once. Do not ask a series of questions.
- Never create a workstream. If none fits, say so and ask.
- Never create a ticket subtask. `todoist-ticket-sync` owns that.
- Never delete a task. Complete it or demote it.
- Never edit a Jira description, and never add a Jira comment.
- Never change a Jira due date. Report a stale one instead.
- Do not move a ticket out of `Blocked` unless the blocker is gone.
- Do not touch a personal task.
- Keep the promoted set small. A long Today is the problem, not the fix.
- A second run with no work between changes nothing. Keep the sweep idempotent.
- If the user declines, do nothing, and do not ask again in this session.

## Related

- `todoist-ticket-sync` syncs one ticket when a branch starts or ends. This
  skill sweeps the whole board on demand. Keep the two separate.
- `finish-branch` owns the Jira transition for a branch.
- `worklog` writes the day into the journal.
