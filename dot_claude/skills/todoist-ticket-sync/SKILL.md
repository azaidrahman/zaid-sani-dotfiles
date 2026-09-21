---
name: todoist-ticket-sync
description: Use when work on a tracker ticket starts or ends (Jira today) - a branch or worktree is created or deleted for a key like GTI-273, the user says "start GTI-NNN", "finish this branch", "I'm done with this ticket", or a hook reports that a ticket started or finished. Makes the matching Todoist update without a question when the update is clear, and asks only in the listed unclear cases.
---

# Keep Todoist level with the tracker

The tracker holds every ticket. Todoist holds the small set of work that the
user does now. The two drift apart when a ticket starts or ends and only the
tracker changes.

Jira is the tracker today. The script reaches it through a provider, so
another tracker is one class and one registry entry away. Run
`ticket-to-todoist.py --providers` to see which are present.

This skill closes that gap. It runs at two moments:

- A ticket starts. A branch or a worktree is created for a key.
- A ticket ends. A branch or a worktree is deleted for a key.

## Act alone, or ask

Make the update without a question when the correct update is clear. Report
what you did in one line. Do not describe the plan first.

Ask the user only in these cases:

- The key has no task in Todoist. A new task needs a project, a section, and
  labels that you cannot read from the ticket alone.
- More than one task matches the key.
- The ticket looks like a live break, which changes the priority to `p1` and
  moves the task to `Ops & Firefighting`.
- The work of a finished ticket did not land, or you cannot tell that it
  landed.
- A write fails, or the result does not match what you sent.

In an unclear case, use one `AskUserQuestion` call for the whole proposal.

Ask nothing else. A question about a routine priority or due date wastes the
time of the user.

## The board

`Work` is an empty parent project. The work lives in five sub-projects.

| Project | Holds |
|---|---|
| `Infra Work` | Build work that the user owns. One section for each epic. |
| `Team Requests` | Requests from other teams. |
| `Ops & Firefighting` | Broken things and incidents. |
| `Admin & Compliance` | Process, documentation, audits, and reports. |
| `Learning` | Books and study. |

### Every ticket is a top-level task

One ticket is one task. The task sits at the top level of its project. The
title starts with the key, for example
`GTI-673 db: add Cloud SQL for GT Console prod`.

**Never create a task that only groups other tasks.** A first-level task
that reads `Finish in-flight work`, `Platform hygiene backlog`, or any other
status name is banned. Such a task holds no work of its own. It repeats the
tickets below it, and it goes stale when the status changes. The user
deleted the last one on 2026-09-21.

A section does the grouping instead. A section carries no date and no
priority, so a reader cannot mistake it for work.

### Sections are epics

In `Infra Work`, each section is one epic. Name the section for the epic,
and put the key in brackets, for example
`GT Console prod re-platform (GTI-671)`.

```
Infra Work
  GT Console prod re-platform (GTI-671)
    GTI-673 db: add Cloud SQL for GT Console prod
    GTI-714 sec: decide the GT Console prod OIDC issuer
  Hermes consolidation (GTI-611)
    GTI-626 gke: add nodeSelector support to platform-lib
```

Urgency does not live in a section. The priority and the due date carry it.
A ticket that the user works on today is `p2` and due today, whatever
section holds it.

A blocked ticket keeps its epic section and takes the `blocked` label. A
section cannot show that a ticket is blocked, because the ticket already
sits in the section for its epic.

### Labels

Every ticket carries `gti`. A ticket also carries a system label
(`gtconsole`, `hermes`, `ufb`, `llmrag`, `iris`, `obs`, `platform`) and an
environment label (`dev`, `stg`, `prd`) when the ticket names one. A blocked
ticket also carries `blocked`.

## Which tool to use

Use the Todoist MCP tools (`mcp__todoist__*`). If they are not present, tell
the user and stop.

## When a ticket starts

1. Find the task. Call `find-tasks` with `searchText` set to the key.

2. Act on what you find.

   **Exactly one task exists.** This is the normal case, and it is clear.
   Make these changes now:
   - Set the priority to `p2`.
   - Set the due date to today.

   Then report the change in one line. If the ticket is a live break, stop
   and ask instead, because a break also changes the project.

   A priority and a due date are enough. Both put the ticket in Today and in
   Upcoming, which is where the user looks. Do not change the section. The
   epic of the ticket does not change when the work starts.

   **No task exists, or more than one matches.** This is unclear. Read the
   ticket in the tracker and ask the user. For a new task, propose:
   - Title: `<KEY> <the ticket summary>`
   - Project: the project that fits.
   - Section: the section for the epic of the ticket. Name your choice and
     say why.
   - Labels: `gti`, plus the system and environment labels that fit.
   - Description: the body of the ticket, then the link. See below.

3. In an unclear case, show the ticket, the task you propose, and the
   changes. Use one `AskUserQuestion` call. Give the user a way to skip.
   Write only what the user accepts.

## What goes in the description

**Do not write the description yourself.** A script does it, so the same
ticket always makes the same text.

```bash
# Print the text for one ticket. Writes nothing.
~/.claude/skills/todoist-ticket-sync/ticket-to-todoist.py GTI-673

# Write it to the matching Todoist task.
~/.claude/skills/todoist-ticket-sync/ticket-to-todoist.py GTI-673 --apply

# Refresh every task whose title starts with a key.
~/.claude/skills/todoist-ticket-sync/ticket-to-todoist.py --all --apply
```

The script reads the ticket through `twg`, converts the body from Atlassian
Document Format to Markdown, cuts it at the first horizontal rule, and adds a
link. It skips a task that already holds the right text, so a second run
changes nothing.

`--all` without `--apply` reports what would change. Run that first.

The script needs a Todoist token. Set `TODOIST_API_TOKEN`, or set
`TODOIST_OP_REF` to a 1Password reference. `exports.zsh` already sets the
reference on both devices.

To read it, the script first takes the 1Password service account token from
the keychain entry `op-service-account-token-personal`, the same entry that
`git-credential-op` uses. That keeps the read headless. Without it, `op`
asks the desktop app instead, which waits for a person to unlock it and
therefore hangs in a hook. Override the entry with `TODOIST_OP_SA_ENTRY`.

The script needs no tracker token: the Jira provider reads through `twg`,
which already holds the Atlassian credential.

**What the script cannot decide.** It copies the ticket faithfully. It does
not know that a ticket is unworkable as written, or that one item in a list
must come first. When you read a ticket and find something like that, add a
comment to the task with `add-comments`. Do not put it in the description,
because the next run of the script overwrites the description. Do not make a
task to hold it.

## When a ticket ends

1. Find the task by key, as above.

2. Check that the work landed. Do not complete a task for a branch that did
   not merge.

3. Act on what you find.

   **One task, and the work landed.** This is clear. Complete the task for
   the key and report it in one line.

   **Anything else.** Ask the user. This covers a branch that did not merge, a
   branch whose state you cannot read, and a key with no task or more than one
   task.

4. If the task was the last open task in its section, say so in the report.
   Leave the empty section. The user removes a section when the epic closes.

## Working with the Todoist API

These three facts cost a session each to find. Trust them.

- **`update-tasks` cannot set `parentId` to null.** The call fails. To lift
  an old subtask to the top level, send `update-tasks` with the `projectId`
  that the task already has. Todoist reads any `projectId` or `sectionId` as
  a move, and a move drops the parent. Verified on 2026-09-21.
- **A delete removes every subtask.** Before you delete an old grouping
  task, read it and confirm that it reports `children: []`.
- **`reschedule-tasks` needs `date`, not `dueString`.** To clear a date, use
  `update-tasks` with `dueString` set to `no date`. `reschedule-tasks`
  rejects that value.

## Rules

- Ask only in the cases under "Act alone, or ask". Otherwise write the
  change and report it.
- One question, not a series. Put the whole proposal in one
  `AskUserQuestion` call.
- Never create a task that only groups other tasks. Use a section.
- Do not create a section. If no section fits, say so and ask.
- Do not change a Jira status here. `finish-branch` owns the Jira
  transition where that skill exists.
- Do not remove the `blocked` label unless the blocker is gone.
- If you find an old grouping task with subtasks below it, do not rebuild
  it and do not silently flatten it. Report it, and offer to flatten it.
- If the user declines, do nothing and do not ask again in this session.
- If a write fails, say so. Do not retry the same call twice.

## Related

- `start-worktree` creates the branch and the worktree for work with no
  ticket.
- `branch-name-ticket` checks that a branch name carries a key.
- `wrap-session` closes out every repository at the end of a session.
