---
name: todoist-ticket-sync
description: Use when work on a Jira ticket starts or ends - a branch or worktree is created or deleted for a key like GTI-273, the user says "start GTI-NNN", "finish this branch", "I'm done with this ticket", or a hook reports that a ticket started or finished. Offers the matching Todoist update and asks the user before it writes.
---

# Keep Todoist level with Jira

The Jira board holds every ticket. Todoist holds the small set of work that
the user does now. The two drift apart when a ticket starts or ends and only
Jira changes.

This skill closes that gap. It runs at two moments:

- A ticket starts. A branch or a worktree is created for a key.
- A ticket ends. A branch or a worktree is deleted for a key.

**Always ask before you write to Todoist.** The user decides. This skill
proposes; it never acts alone.

## The board

`Work` is an empty parent project. The work lives in five sub-projects.

| Project | Holds |
|---|---|
| `Infra Work` | Build streams that the user owns. Sections: `Now`, `Next`, `Blocked`. |
| `Team Requests` | Requests from other teams. |
| `Ops & Firefighting` | Broken things, incidents, and work already in flight. |
| `Admin & Compliance` | Process, documentation, audits, and reports. |
| `Learning` | Books and study. |

In `Infra Work` and `Team Requests`, a top-level task is a **workstream**. Its
subtasks are the Jira tickets in that stream. Each subtask title starts with
the key, for example `GTI-673 db: add Cloud SQL for GT Console prod`.

Labels: every ticket carries `gti`. A ticket also carries a system label
(`gtconsole`, `hermes`, `ufb`, `llmrag`, `iris`, `obs`, `platform`) and an
environment label (`dev`, `stg`, `prd`) when the ticket names one.

## Which tool to use

Use the Todoist MCP tools (`mcp__todoist__*`). If they are not present, tell
the user and stop.

## When a ticket starts

1. Find the task. Call `find-tasks` with `searchText` set to the key.

2. Act on what you find.

   **The task exists.** This is the normal case. The ticket is already a
   subtask of a workstream. Propose these changes:
   - Move it to the `Now` section of its project, or to `Ops & Firefighting`
     if the ticket is a live break.
   - Set the priority to `p2`, or to `p1` if the ticket is a live break.
   - Set the due date to today.

   **The task does not exist.** The ticket is new since the last sweep. Read
   the ticket in Jira. Propose a new subtask:
   - Title: `<KEY> <the Jira summary>`
   - Parent: the workstream that fits. Name your choice and say why.
   - Labels: `gti`, plus the system and environment labels that fit.
   - Description: the body of the ticket, then the link. See below.

3. Ask the user. Show the ticket, the task you found or propose, and the
   changes. Use one `AskUserQuestion` call. Give the user a way to skip.

4. Write only what the user accepts.

## What goes in the description

**Do not write the description yourself.** A script does it, so the same
ticket always makes the same text.

```bash
# Print the text for one ticket. Writes nothing.
~/.claude/skills/todoist-ticket-sync/jira-to-todoist.py GTI-673

# Write it to the matching Todoist task.
~/.claude/skills/todoist-ticket-sync/jira-to-todoist.py GTI-673 --apply

# Refresh every task whose title starts with a key.
~/.claude/skills/todoist-ticket-sync/jira-to-todoist.py --all --apply
```

The script reads the ticket through `twg`, converts the body from Atlassian
Document Format to Markdown, cuts it at the first horizontal rule, and adds a
link. It skips a task that already holds the right text, so a second run
changes nothing.

`--all` without `--apply` reports what would change. Run that first.

The script needs a Todoist token. Set `TODOIST_API_TOKEN`, or set
`TODOIST_OP_REF` to a 1Password reference such as
`op://Private/Todoist/credential`. It needs no Jira token, because `twg`
already holds the Atlassian credential.

**What the script cannot decide.** It copies the ticket faithfully. It does
not know that a ticket is unworkable as written, or that one item in a list
must come first. When you read a ticket and find something like that, add one
short line at the top of the **parent** task, not the subtask. The next run of
the script overwrites a subtask description.

## When a ticket ends

1. Find the task by key, as above.

2. Check that the work landed. Do not complete a task for a branch that did
   not merge. If you cannot tell, ask.

3. Ask the user. Propose these changes:
   - Complete the subtask for the key.
   - If the subtask was the last open subtask of its workstream, say so, and
     ask whether to complete the workstream too.

4. Write only what the user accepts.

## Rules

- One question, not a series. Put the whole proposal in one
  `AskUserQuestion` call.
- Do not create a workstream. If no workstream fits, say so and ask.
- Do not change a Jira status here. `finish-branch` owns the Jira
  transition where that skill exists.
- Do not move a ticket out of `Blocked` unless the blocker is gone.
- If the user declines, do nothing and do not ask again in this session.

## Related

- `start-worktree` creates the branch and the worktree for work with no
  ticket.
- `branch-name-ticket` checks that a branch name carries a key.
- `wrap-session` closes out every repository at the end of a session.
