---
name: task-sweep
description: Use when the user wants a review of their Jira board - "my tickets are a mess", "too much overdue", "what should I focus on today", "sort out my tickets", "do I have duplicate tickets". Reads the open tickets assigned to the user, then reports overdue dates, status mismatches, possible duplicate tickets, and a short focus list. This skill does not write to Jira.
---

# Review the Jira board on demand

The board drifts over time. Due dates pass. Tickets stay In Progress after
the work is done. Two tickets can describe the same work. This skill runs
when the user asks for it. It is not scheduled, and it does not run on a
branch event.

**Read everything first. Report once. Write nothing.**

## Which tool to use

Use the Atlassian MCP tools to read Jira. If they are absent, tell the user
and stop.

## The review

### 1. Read the open tickets

Read the open tickets that the user is assigned. Record for each ticket:

- the key and the summary
- the status
- the due date, if there is one
- the priority
- the links to other tickets, with the link type

### 2. Find overdue tickets

A ticket is overdue when its due date is before today. Report each one with
the number of days past the date.

Do not change the due date. A missed due date is a missed commitment for
other people. It needs a conversation, not a silent change.

### 3. Find status mismatches

- If a ticket is Done and a local branch still carries its key, report it.
  Say that `finish-branch` closes that branch.
- If a ticket is In Progress and has no local branch that carries its key,
  report it as a question. Do not assume it is wrong.

### 4. Find redundant tickets

Compare the open tickets with each other. Report a pair in one of two ways.

- **Linked.** A link of type Duplicate joins the two tickets. Report it as
  confirmed.
- **Similar summary.** Lowercase both summaries. Remove the key and any area
  prefix, such as `gke:`. Remove words of three letters or fewer. If the
  shared words are at least 60% of the shorter summary, report the pair as
  possible. Say that the check compares words only.

For each pair, show both keys, both summaries, and the reason. Do not decide
which ticket to keep. Do not link, close, or edit either ticket.

### 5. Propose a focus list

Pick the In Progress tickets that the user should work on today. Keep the
list short. If the user passes a number, for example `/task-sweep 3`, use
that number as the limit.

The focus list is a suggestion. The skill does not change any ticket.

## The report

Present one report, grouped by finding. Show the count in each group. Omit
an empty group.

```text
Overdue (2)
  GTI-592  due 2026-07-30, 74 days past

Done with a branch (1)
  GTI-701  Done in Jira. Branch feat/GTI-701-... still exists. Run finish-branch.

Check (1)
  GTI-310  In Progress, no local branch carries the key. Still active?

Possible duplicates (1)
  GTI-624  gke: template nodeSelector in platform-lib
  GTI-626  gke: add nodeSelector support to platform-lib
  Reason: similar summary. Confirm whether one replaces the other.

Focus today (3)
  GTI-767  gke: stand up prd host and shared cluster
  GTI-673  db: add Cloud SQL for GT Console prod
```

Do not ask a question after the report. The user reads it and decides.

## Rules

- Never write to Jira. Do not change a status, a due date, a description, a
  comment, or a link.
- Never change a local branch. `finish-branch` owns branch cleanup.
- Never decide which duplicate to keep. Report the pair only.
- Report once per run. Do not ask a series of questions.
- Keep the focus list small. A long list is the problem, not the fix.
- A second run with no change between runs gives the same report.

## Related

- `finish-branch` closes a branch and moves its ticket to Done.
