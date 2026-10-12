---
name: worklog
description: Use when the user runs /worklog start or /worklog stop, or asks to sync their assigned Jira tickets into their work log or recap the work day. start pulls Jira issues assigned to the user and writes the day's focus set to the worklog CSV; stop refreshes those rows against Jira and adds a recap plus a next-day look-ahead.
---

# worklog

Bridges Jira and a work log kept as one CSV file. Two modes, invoked manually.
The daily journal notes are not touched.

## When to use

- `/worklog start` - beginning of the work day: pull the user's open Jira
  tickets, discuss with them what to focus on today, then write the agreed set
  to the worklog CSV.
- `/worklog stop` - end of the work day: refresh the day's rows against Jira,
  then write a short recap and a look ahead at next day's likely tasks.

If the user invokes `/worklog` with no argument, ask whether they mean `start`
or `stop`.

## Fixed facts

- Vault root: `$OBSIDIAN_VAULT` (the Polaris vault, `~/vaults/Polaris`).
- Work log file: `<vault>/2-Journals/worklog.csv`. Do not read or write any
  other file for this skill.
- Helper script: `~/.claude/skills/worklog/worklog-csv.py` (next to this file).
  Use it for every read and write of the CSV. Do not edit the CSV by hand.
  - `worklog-csv.py read <YYYY-MM-DD>` prints the day's rows as JSON.
  - `worklog-csv.py write <YYYY-MM-DD>` reads a JSON object from stdin. The
    input format is in the script header.
- Today's date: `date "+%Y-%m-%d"`.
- Jira: use the connected Atlassian MCP. The cloud id comes from
  `getAccessibleAtlassianResources`; current user from `atlassianUserInfo`;
  issues from `searchJiraIssuesUsingJql`.

## CSV format

Header: `date,kind,key,summary,status,done,note`

- `kind` is `task` or `recap`.
- Task row: `key` is the Jira key, or empty for a non-Jira task. `summary` is a
  short label of a few words. `status` is the Jira status name, or empty.
  `done` is `true` or `false`.
- Recap row: one per day. `summary` holds the recap. `note` holds the
  `Next day:` line. `key`, `status`, and `done` are empty.
- A day has one set of task rows and at most one recap row.

## Writing rules

- Never write the em dash character U+2014 in any output. Use a plain hyphen with
  spaces ( - ) instead.
- Keep labels short. Do not copy a long Jira summary. Do not add branch names,
  PR state, or multi-clause prose.
- Only the focus set for the day goes in the task rows, never the full open
  backlog.
- The recap is at most three short sentences. The `next_day` line is one line.

## start procedure

This mode is a conversation, not a dump. Pull the user's open work, talk through
priorities with them, and only write the set they choose to focus on today.

1. Get the date: `date "+%Y-%m-%d"`.
2. Resolve Jira access:
   - Call `getAccessibleAtlassianResources` and take the first resource's `id`
     as the cloud id and its `url` as the site base.
3. Query open issues with `searchJiraIssuesUsingJql`:
   - cloudId: from step 2.
   - jql: `assignee = currentUser() AND statusCategory != Done ORDER BY status ASC, updated DESC`
     (Done/Closed are excluded on purpose - the morning list is about open work.)
   - fields: `["summary", "status"]`
   - maxResults: 50
   - The response can be large. If the tool reports the result was saved to a
     file because it exceeded the size limit, extract just key, status, and
     summary with `jq`, e.g.
     `jq -r '.issues.nodes[] | "\(.key)\t\(.fields.status.name)\t\(.fields.summary)"' <file>`.
4. Discuss with the user. Present the open tickets grouped by status (key,
   summary, status - concise), then ask which they want to focus on today. Let
   them pick a subset, reprioritise, or name extra tasks that are not in Jira.
   Wait for their decision before writing anything.
5. Build the JSON for the agreed set:
   - Jira task: `{"key": "GTI-1", "summary": "<short label>", "status": "<status name>", "done": false}`
   - Non-Jira task the user named: `{"key": "", "summary": "<short task text>", "status": "", "done": false}`
   - If the user chooses nothing, send `{"tasks": []}`.
6. Write it. Pipe the JSON to the helper:
   `echo '<json>' | ~/.claude/skills/worklog/worklog-csv.py write <YYYY-MM-DD>`.
   The write replaces the day's task rows. It keeps the day's recap row if one
   exists, so re-running start is safe.
7. Report to the terminal: number of tasks written and the CSV path.
8. Offer the tmux session sync (see below). This is opt-in - ask once, act only
   if the user says yes.

## tmux sessions per ticket (start, opt-in)

After the focus set is written, offer to give each Jira focus ticket its own
detached tmux session, so the user can attach and start working immediately.
Only for the Jira tickets in today's focus set - skip non-Jira task rows.

The deterministic mechanics - liveness check, worktree lookup, session creation,
duplicate/illegal-name guards - live in `worklog-tmux-session.sh` (next to this
file). Do not re-type those commands inline; call the script. The agent's only
job is the loop, skipping non-Jira rows, and handling the one case the script
can't (creating a missing worktree, whose slug needs the Jira summary).

For each **Jira** ticket KEY in the focus set, run:

```bash
~/.claude/skills/worklog/worklog-tmux-session.sh "<KEY>"
```

Act on the exit code:

| Exit | stdout | What it means / do next |
|------|--------|--------------------------|
| `0`  | `already-live: <name>` or `created: <name>` | Done - report it, next ticket. |
| `3`  | `no-worktree: <KEY>` | No worktree yet. Invoke the `start-ticket-worktree` skill for `<KEY>` to create the branch + worktree, then **re-run the script** (it now finds the worktree and creates the session). When using start-ticket-worktree here, **skip its Step 8 tmux tagging** - that renames the *current* window (running worklog); the script names the new session itself. Also **skip its `EnterWorktree` step** - this session must stay put, and the new session starts in the worktree by itself. |
| `2`  | error on stderr | Precondition failed (repo not found / no tmux server). Report and skip the whole sync - don't improvise. |

The script is idempotent: it matches existing sessions on the `<KEY>` prefix (so
key-only sessions like `GTI-333` count), names new ones `<KEY>-<slug>` after the
worktree directory, and roots them there with `tmux new-session -c`. Re-running
`/worklog start` never duplicates a session. It assumes GTI worktrees live in
`gtech-atlas` (override with a second arg: `... "<KEY>" "/path/to/repo"`).

### Launch Claude in each session (opt-in)

After the sessions exist, optionally kick off a Claude Code instance inside each
one that immediately runs `/start-ticket-worktree` for its ticket - so attaching drops the
user straight into an agent already oriented on that ticket. Ask once before
doing this; act only if the user says yes.

The session name equals the worktree directory tail (the `created:`/`already-live:`
value the script printed), so send the launch command straight to it. For each
Jira focus ticket KEY with a live session `<SESSION>`:

```bash
tmux send-keys -t "<SESSION>" "claude \"/start-ticket-worktree <KEY>\"" Enter
```

Notes:
- Send only to sessions the script reported as `created`/`already-live` - never to
  a session that failed provisioning.
- The worktree and branch already exist by this point, so `/start-ticket-worktree` finds
  them and reports the path rather than recreating - that is expected and fine.
- This launches an interactive agent per session; do not wait on or drive them
  from the worklog session. Just report which sessions were launched.

## stop procedure

1. Get the date (same as start, step 1).
2. Read the day's rows: `~/.claude/skills/worklog/worklog-csv.py read <YYYY-MM-DD>`.
   If there are no task rows, run the `start procedure` first, then continue.
3. Collect the Jira keys from the task rows (skip rows with an empty key).
   Re-query just those with `searchJiraIssuesUsingJql`, jql
   `key in (KEY1, KEY2, ...)`, fields `["summary", "status"]`. This catches
   tickets that moved to Done during the day.
4. Update each Jira task row: set `status` to the current status name. Set
   `done` to `true` when the status category is done
   (`fields.status.statusCategory.key == "done"`), otherwise `false`. Keep the
   `done` value of non-Jira rows as the user left it.
5. Write the recap:
   - Narrative recap: at most three short sentences on what changed today
     (tickets closed, moved, or newly assigned).
   - Next day: the likely tasks to pick up - tickets still in progress and the
     natural next step on anything closed today. One line.
6. Write everything for the day in one call. Send the updated tasks and the
   recap as JSON:
   `echo '{"tasks": [...], "recap": "...", "next_day": "..."}' | ~/.claude/skills/worklog/worklog-csv.py write <YYYY-MM-DD>`.
   The write replaces the old recap, so a recap is never stacked. Confirm the
   JSON has no U+2014 character.
7. Report to the terminal: counts of done vs open tasks and the CSV path.
