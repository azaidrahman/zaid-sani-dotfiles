---
name: start-ticket-worktree
description: Use when the user wants to start work on one or more Jira tickets — "start GTI-273", "kick off this ticket", "let's work on GTI-NNN", "make a worktree for this ticket", "start GTI-A, GTI-B and GTI-C", "spin each ticket up in its own Rex tab", or any time fresh work begins from a ticket key. Use this personal version, not general:start-ticket-worktree (that one drives tmux; this user is on Rex). Creates an isolated git worktree per ticket on a properly-named branch (`<type>/<KEY>-<slug>`) branched from the repo's default integration branch, so PRs, CI, and `git log` trace back to the ticket without later renames.
---

# Start work on a ticket

Given a Jira ticket key, set up an isolated workspace: a new branch named `<type>/<KEY>-<slug>` and a git worktree at `.worktrees/<KEY>-<slug>`, branched from the right base. Hand the user back a path they can `cd` into. Optionally — and required when the user wants more than one ticket "each in its own tab" — also open a Rex window (a tab) rooted in each worktree.

> **Personal override.** This copy replaces `general:start-ticket-worktree` from the gtech-skills marketplace. The user moved from tmux to Rex. The tmux steps are commented out (`<!-- tmux disabled -->` blocks) and Rex steps replace them. Do not run a commented-out tmux command. `worktree-setup.sh` here is a symlink to the marketplace copy, so it follows upstream.

## The mechanics are scripted — you do the judgment

The deterministic half of this skill lives in **`start-ticket-worktree.sh`** (next to this file): fetch, base resolution, the conflict matrix, worktree+branch creation, and Rex window creation. It is idempotent and safe for repeated and concurrent use, so several callers — a batch loop, the [[worklog]] skill, the [[handoff]] skill, you at the shell — can all invoke it without colliding (a Rex block tagged `ticket:<KEY>` or `handoff:<KEY>` counts as an open tab, and `worklog-rex-tab.sh` uses the same tags, so none of them double-creates a tab).

<!-- tmux disabled: "its tmux session naming matches [[worklog]]'s so the two never double-create a session" -->

**Your job is Steps 1–4 — the judgment the script deliberately does NOT do:** resolve an ambiguous key, fetch Jira, the Epic-vs-Task check, and mapping an unlisted issue type. Once you hold a resolved `KEY TYPE SLUG`, hand them to the script — do **not** hand-roll `git worktree add` or `rex api call … session.new_window` yourself (the baseline failure this skill exists to prevent: agents reinvent the idempotency, name sanitizing, and worktree-rooting the script already gets right, and reinvent it inconsistently).

```bash
SH=~/.claude/skills/start-ticket-worktree/start-ticket-worktree.sh
"$SH" <KEY> <TYPE> <SLUG> [--session] [--no-fetch] [--base B] [--repo P]
```

## Naming contract (STRICT — no deviation)

Every branch and worktree this skill creates MUST satisfy all four rules below. These are not guidelines you weigh — they are invariants. If you cannot satisfy one, **stop and ask the user**; never improvise a variant that "looks close enough".

1. **Shape & order — `<type>/<KEY>-<slug>`, exactly.** One `<type>`, one literal `/`, the `<KEY>`, one literal `-`, then the `<slug>`. No other separators, no extra path segments, no trailing `/` or `-`. The `<KEY>` is **always uppercase** (`GTI-273`, never `gti-273` or `Gti-273`).
2. **Type — closed set only.** `<type>` ∈ {`feat`, `fix`, `chore`, `docs`}. Nothing else is permitted. Derive it via the Step 3 table. If the Jira issue type maps to none of these and the user gives no override, **stop and ask** — do NOT default to `feat` or invent a type.
3. **Slug — deterministic.** The same summary MUST always produce the same slug. Apply the Step 4 rules mechanically, in the listed order — no judgment calls, no synonyms, no creative rephrasing, no abbreviations not produced by the rules. Hard cap 30 chars.
4. **Worktree mirror — `.worktrees/<KEY>-<slug>`.** The directory tail equals the branch's `<KEY>-<slug>` **byte-for-byte**, with NO `<type>/` prefix. If the branch tail and the directory tail ever differ, that's a bug — fix the names before creating anything, don't proceed.

`start-ticket-worktree.sh` enforces this self-check before it creates anything (Step 5): the string after the last `/` in the branch must equal the worktree dir's tail. If you ever compose names by hand, halt on a mismatch — don't proceed.

## When to use

- User says: "start GTI-273", "let's work on this ticket", "kick off GTI-NNN", "make a worktree for X", "spin up a branch for this Jira ticket".
- Beginning any new feature/fix/chore that already has a Jira ticket.
- Before any work that will eventually become a PR — start it right so [[branch-name-ticket]] never has to rename it.

**Skip when:**

- The current branch is already the right one for this ticket — just keep working.
- The work has no ticket and won't get one (rare — confirm with the user; if true, fall back to a plain `git checkout -b`).
- You're already inside a `.worktrees/<KEY>-...` directory for the same ticket.

## Pre-checks

Confirm you're somewhere sane and capture the repo root (worktrees hang off it):

```bash
git rev-parse --is-inside-work-tree       # must be true
REPO=$(git rev-parse --show-toplevel)     # repo root
git remote get-url origin 2>/dev/null     # confirm remote exists
```

You do **not** fetch or resolve the base branch yourself — `start-ticket-worktree.sh` does both (`git fetch --prune`, then `origin/HEAD` falling back `develop`→`main`, and it reports which base it used). The one exception is a batch: fetch once up front and pass `--no-fetch` to each call (Step 6, Batch).

## Step 1 — Resolve the ticket key

In order, stop at the first that yields a confident answer:

1. **Argument from the user message** — extract `[A-Z]+-[0-9]+` (case-insensitive, normalize to uppercase).
2. **Rex labels** — if `$REX_SESSION` is set, the label of this pane's block (`ticket:<KEY>` or `handoff:<KEY>`) or of its window may already carry the key:

   ```bash
   rex block ls -s "$REX_SESSION" --json | jq -r --arg b "$REX_BLOCK" '.blocks[] | select(.block_id == $b) | .label, .window_id' \
     | { read -r blabel; read -r wid; echo "block: $blabel"
         rex window ls -s "$REX_SESSION" --json | jq -r --arg w "$wid" '.windows[] | select(.window_id == $w) | "window: \(.label)"'; }
   ```

   <!-- tmux disabled:
   2. **Tmux window name** — if `$TMUX` is set: `tmux display-message -p '#W'` may already carry the key (set by [[rename-tmux-to-ticket]]).
   -->
3. **Ask the user** — one short `AskUserQuestion` with the top 3–5 candidates from `mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql` (`assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`, limit 5). Load the MCP tool first via `ToolSearch` if it isn't resolved.

Stop and ask if you have no signal — do not invent a key.

## Step 2 — Fetch ticket details

Get `cloudId` once via `mcp__claude_ai_Atlassian__getAccessibleAtlassianResources`, then:

```
mcp__claude_ai_Atlassian__getJiraIssue(
  cloudId=<id>,
  issueIdOrKey="<KEY>",
  fields=["summary", "issuetype", "status"]
)
```

If Atlassian MCP is unavailable, tell the user, and ask them for the summary + type in one prompt. Never fabricate either.

## Step 2.5 — Is this really an Epic? (organize before you branch)

Before setting up a single branch, sanity-check the *shape* of the work. A ticket that is actually an umbrella shouldn't be worked as one branch — it should be an **Epic** with child Tasks, and you branch off a child.

**Signals it's epic-sized** (any one is a strong hint, two is decisive):

- Summary lists multiple services/tracks (`iris/kongc/wfb/rag`, "a + b + c").
- Body has phases, multiple tracks, or several independently-shippable deliverables.
- Original estimate ≥ ~1 week, or the user describes work spanning many sittings.
- You'd struggle to write one focused PR / one "Done when" for it.

**If it looks epic-sized**, surface it with one `AskUserQuestion` before creating anything:

> "GTI-NNN looks epic-sized (3 tracks, ~2 weeks). Make it an **Epic** and split the tracks into child Tasks, then start a branch on the first child? Or branch this as one ticket?"

- **Make it an Epic** → convert the type (`editJiraIssue` `issuetype` → Epic id), create one child Task per track (`parent` = the epic), then **run Step 3+ on the most-actionable child**, not the epic. Epics don't get feature branches.
- **Keep as one ticket** → proceed normally.

If the ticket is already an Epic, don't branch off it — ask which child to start (or create one), then continue with that child key.

Keep it light: this is a 10-second judgment + one question, not a planning exercise. A clearly single-deliverable ticket skips this step entirely.

**Handed several keys at once?** This check is about the *shape of one ticket*, not the batch. If the user names N distinct keys (`start GTI-A, GTI-B, GTI-C`), do NOT fire the Epic question just because the set spans services — they are already separate, filed tickets. Apply this judgment per individual key (a single key that is itself epic-sized still gets the question), then proceed to the batch flow in Step 6.

## Step 3 — Derive `type` from issue type

`<type>` MUST be one of `feat` / `fix` / `chore` / `docs` (contract rule 2). Map via this table:

| Jira issue type | Branch type |
|---|---|
| Story, Task, New Feature, Epic (rare for branches) | `feat` |
| Bug, Defect, Incident | `fix` |
| Sub-task | inherit parent's type, else `feat` |
| Chore, Maintenance | `chore` |
| Documentation | `docs` |
| Spike, Research | `chore` |
| **anything not listed above** | **STOP — ask the user which of the four applies. Do not default to `feat`.** |

If the user explicitly says "this is a docs-only change" or similar, honor that override (still within the four allowed types).

## Step 4 — Derive the slug from the summary

Apply these rules **mechanically and in order** — the same summary must always yield the same slug (contract rule 3). No judgment calls or creative rephrasing. Same rules as [[branch-name-ticket]] and [[rename-tmux-to-ticket]]:

- **First, strip a leading `<area>: ` prefix** if the title follows the [[writing-tickets]] house style (`db: add PSC support…` → slugify `add PSC support…` only). The area is already captured by the branch `<type>/` segment, so it never enters the slug.
- Lowercase; strip punctuation, em/en dashes, parentheses.
- Drop fillers: `the a an of for to on in and with into from by`.
- Drop ceremony verbs at the start: `create make setup set add build write do enable get give`.
- Drop generic leading nouns when something specific follows: `request permission access task ticket project`.
- Keep the first 2–4 *meaningful* tokens, kebab-joined.
- Hard cap: 30 chars. Drop trailing tokens if over.

Examples:

| Summary | Slug |
|---|---|
| "Create project Nova" | `project-nova` |
| "Add IAP permissions for Iqhwan on GTConsole" | `iap-iqhwan-gtconsole` |
| "Fix Cloud Run keyless auth docs" | `cloud-run-keyless-auth` |
| "db: add PSC support to cloud_sql" | `psc-cloud-sql` |
| "proj: decommission iris cluster" | `decommission-iris` |

## Step 5 — Create the worktree (call the script)

You now hold a resolved `KEY`, `TYPE` (Step 3) and `SLUG` (Step 4). Hand them to `start-ticket-worktree.sh` — it composes the names, enforces the Naming contract (including the byte-for-byte tail self-check), runs the conflict matrix, fetches, resolves the base, and creates the worktree+branch. Do **not** run `git worktree add` by hand.

```bash
SH=~/.claude/skills/start-ticket-worktree/start-ticket-worktree.sh
"$SH" "$KEY" "$TYPE" "$SLUG"     # add --session to also open a Rex tab (Step 6, Mode B)
```

Read the exit code and act:

| Exit | Means | Do |
|---|---|---|
| `0` | Worktree ready. stdout: `worktree: created\|reused\|tracked-remote <BRANCH> <DIR>` | Report it (Step 7). |
| `4` | Path exists but is NOT a worktree for this branch — possibly a stale checkout with real work | **Stop. Ask the user.** The script refused to overwrite; never `--force` or `rm`. |
| `2` | Bad input / not a git repo (message on stderr) | Fix the inputs (re-derive `TYPE`/`SLUG`); never improvise a name to slip past it. |

What the script does (so you can report it accurately): it branches from `origin/$BASE` post-fetch (never local `$BASE`), and never pushes the new branch — pushing is commit/PR time.

| Situation | Script action | stdout |
|---|---|---|
| Nothing exists | `git worktree add -b` from `origin/$BASE` | `worktree: created` |
| Worktree already on `$BRANCH` | reuse, no recreate | `worktree: reused` |
| Local branch exists, no worktree | attach a worktree to it | `worktree: reused` |
| Remote branch exists, no local | `git worktree add -B … origin/$BRANCH` | `worktree: tracked-remote` |
| Path exists, not a worktree | refuse, never overwrite | exit `4` |

## Step 5.25 — The worktree prepares itself

A new worktree has the tracked files only. It has no `node_modules`, no `.env`,
and no other ignored file. After it makes the worktree, the script calls
`worktree-setup.sh` (next to it). Do not install dependencies by hand.

`worktree-setup.sh` does the first step in this list that applies:

1. If the repo has an executable `.worktree-setup.sh`, it runs that script and
   nothing else.
2. It copies the files that match `.worktreeinclude` and that git ignores, from
   the main checkout. Claude Code uses the same file for its own worktrees.
3. It installs dependencies from the lockfile in the worktree root:

| Lockfile | Action |
|---|---|
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `bun.lock`, `bun.lockb` | `bun install --frozen-lockfile` |
| `yarn.lock` | `yarn install --frozen-lockfile` (yarn 2+: `--immutable`) |
| `package-lock.json`, same as the main checkout | Clone the main checkout's `node_modules` (copy-on-write, no install) |
| `package-lock.json`, changed | `npm ci` |

The slow part runs in the background, so the worktree is ready at once. The
script adds one line to stdout. It never changes the `worktree:` or `session:`
lines.

| stdout | Means | Do |
|---|---|---|
| `setup: started <LOG>` | The setup runs in the background | Before you run the app or the tests, check the status (below). |
| `setup: skipped:nothing-to-do` | No lockfile, no `.worktreeinclude`, no repo script | Nothing. |
| `setup: already-done` | A reused worktree that is set up | Nothing. |
| `setup: skipped:disabled` | `--no-setup` or `WORKTREE_SETUP=0` | Nothing. |
| `setup: skipped:<other>` | The setup could not start | Tell the user. The worktree is still ready. |

A failed setup never fails the script. The exit code stays `0`. To check the
status, run:

```bash
SETUP=~/.claude/skills/start-ticket-worktree/worktree-setup.sh
"$SETUP" <WORKTREE> --status     # setup: running|done|failed|none <LOG>
```

If the status is `failed`, read the log and tell the user. The status file and
the log are in the git directory of the worktree, so `git status` does not show
them.

## Step 5.5 — Mark the ticket as started

When the script exits `0`, do the procedure in
`~/.claude/plugins/marketplaces/gtech-skills/general/references/ticket-start.md`
(this personal copy has no `${CLAUDE_PLUGIN_ROOT}`, so use the full path). It moves a To Do ticket to
In Progress, adds a comment that logs the start, and sets an empty start date
to today. `finish-branch` reads the move to In Progress to calculate the time
spent, so do not skip this step.

If the script exits with an error, do not move the ticket. If Atlassian MCP is
unavailable, tell the user which key to move by hand, and continue.

## Step 6 — Rex: pick the mode that matches the request

Two distinct situations. Choosing the wrong one is the central failure mode: renaming the *current* window for a multi-ticket request clobbers the same window N times (last write wins) and leaves the user no tab per ticket.

### Mode A — one ticket, you'll work in the current window

The default for a plain single `start GTI-NNN`. Rename the current Rex window (the tab) *in place* so it is labeled for the ticket. If `$REX_SESSION` is set, do it automatically (don't ask); if not, skip silently — don't surface "you're not in Rex", it's noise.

1. Build the short label with the Step-4 squeeze rules, capped ~15 chars.
2. `LABEL="<KEY> <short-label>"` (e.g. `GTI-273 project-nova`), total ≤ 25 chars.
3. Rename the window that holds this pane. Resolve its ID from `$REX_BLOCK` — the user may look at a different window, so never rename "the active window":

   ```bash
   WID=$(rex block ls -s "$REX_SESSION" --json | jq -r --arg b "$REX_BLOCK" '.blocks[] | select(.block_id == $b) | .window_id')
   rex window rename -s "$REX_SESSION" "$WID" "$LABEL"
   ```

   Do not change the label of the block. It can hold a tag such as `handoff:<KEY>`, and [[handoff]] finds its tab by that tag.

The SessionStart hook already names the Rex session for the work. Keep that name.

<!-- tmux disabled — Mode A, tmux version:
1. Build the short label with the Step-4 squeeze rules (or invoke [[rename-tmux-to-ticket]]), capped ~15 chars.
2. `LABEL="<KEY> <short-label>"` (e.g. `GTI-273 project-nova`), total ≤ 25 chars.
3. Rename the **current** window + pane — **no `-t`**, because here the current one is the target:

   ```bash
   tmux rename-window  "$LABEL"
   tmux select-pane -T "$LABEL"
   ```

> The `no -t` rule applies to **Mode A only**. Never carry it into Mode B — there, each new session is targeted explicitly, and the script does that for you.
-->

Then **move the session into the worktree**. Call the `EnterWorktree` tool with the absolute path the script reported:

```text
EnterWorktree path=/abs/path/to/repo/.worktrees/<KEY>-<slug>
```

Mode A renames the window, but the rename does not change the directory. Without this call the session keeps writing in the original checkout, and the `/diff` panel stays empty — it reads the repository of the session directory, and `.worktrees/` is git-ignored there. A `cd` in a tool call does not help: the shell directory resets after every command.

**Skip this call when another skill drives Mode A and opens its own window or session for the work** — [[handoff]] and [[worklog]] both do. Those sessions start in the worktree already, and moving *this* session would strand the caller.

To leave the worktree later in the same session, use `ExitWorktree` with `action: keep`. It never deletes a worktree that this skill created.

### Mode B — a Rex tab per ticket, the user switches to it

Use this whenever the user says "its own tab", "its own session", "so I can hop between them", or starts **more than one** ticket. Pass `--session` to the script. It opens a Rex window in the current Rex session (`$REX_SESSION`), with one shell block that starts in the worktree. It does not focus the new window, so the user stays where they are. It tags the block `ticket:<KEY>`. If a placed block already has the label `ticket:<KEY>` or `handoff:<KEY>`, it opens no second window. Do **not** hand-roll `rex window new`, `rex api call … session.new_window`, name sanitizing, or the tag check — that is exactly what the script exists to get right.

```bash
"$SH" "$KEY" "$TYPE" "$SLUG" --session
# stdout adds: session: created|already-live|skipped:<reason> <NAME>
```

Tell the user the tab name, and the command to switch to it:

```
rex window focus -s "$REX_SESSION" <NAME>
```

| `session:` reason | Means |
|---|---|
| `skipped:no-rex` | `$REX_SESSION` is not set. The worktree is ready; say so and give the path. |
| `skipped:no-rex-cli` | `rex` or `jq` is not on `PATH`. The worktree is ready; say so. |
| `skipped:rex-error` | The Rex server refused the new window. The worktree is ready; say so. |

<!-- tmux disabled — Mode B, tmux version:
Pass `--session` to the script — it runs `tmux new-session -d` rooted in the worktree (via `-c`, so attach drops them in the right dir), idempotent, and named to interoperate with [[worklog]] (a bare-key session like `GTI-273` already counts as live, so it never double-creates). Do **not** hand-roll `tmux new-session`, name sanitizing, or `has-session` guards — that is exactly what the script exists to get right.

Hand back the attach commands — `switch-client` from inside tmux, `attach` from outside:

```
tmux switch-client -t <NAME>     # already inside tmux (can't nest-attach)
tmux attach -t <NAME>            # from a plain terminal
```

`session: skipped:no-tmux` means the worktree was still created but tmux was unavailable — just say so.
-->

### Batch — several tickets, each in its own tab

Do the judgment (Steps 1–4) per key first — including the **per-key** Epic check, not one for the whole set (Step 2.5). Then fetch once and loop, passing `--no-fetch` so the network round-trip happens a single time:

```bash
SH=~/.claude/skills/start-ticket-worktree/start-ticket-worktree.sh
git -C "$REPO" fetch --prune origin                            # once for the batch
"$SH" GTI-401 feat  rate-limiting-public-api --session --no-fetch
"$SH" GTI-402 fix   null-pointer-auth-token  --session --no-fetch
"$SH" GTI-403 chore bump-terraform-provider  --session --no-fetch
```

The script is idempotent, so re-running the batch reuses existing worktrees/tabs instead of erroring. A non-zero exit on one ticket (`4` — path exists but not a worktree; `2` — bad input) does **not** abort the loop — each call is independent. Note that ticket, finish the rest, then surface the ones needing a human as their own rows in the report. Report the set as a table (Step 7) plus the switch command.

**Other follow-ups (offer, don't do silently):** tell the user the absolute worktree path(s). Do not `cd` for them — `cd` doesn't persist across shell tool calls, and Mode B already starts each tab in its worktree.

## Step 7 — Report

**Single ticket (Mode A):**

```
Ticket   : GTI-273 — "Create project Nova"  (Story → feat)
Base     : origin/develop @ <short-sha>
Branch   : feat/GTI-273-project-nova
Worktree : /abs/path/to/repo/.worktrees/GTI-273-project-nova
Session  : now working in the worktree
Setup    : pnpm install running in the background (or: nothing to set up)
Jira     : To Do → In Progress, start logged, start date set to 2026-09-23

cd /abs/path/to/repo/.worktrees/GTI-273-project-nova
```

The `cd` line is for the **user's own shell**, not for you — your session moved with `EnterWorktree`. Drop the `Session` line if you skipped that call for a caller that opens its own window.

**Batch / Rex tabs (Mode B):** one row per ticket plus the switch command.

```
Base: origin/main @ <short-sha>

KEY      TYPE   BRANCH                                   REX TAB                       STATUS        JIRA
GTI-401  feat   feat/GTI-401-rate-limiting-public-api    GTI-401-rate-limiting-...     created       → In Progress
GTI-402  fix    fix/GTI-402-null-pointer-auth-token      GTI-402-null-pointer-...      created       → In Progress
GTI-403  chore  chore/GTI-403-bump-terraform-provider    GTI-403-bump-terraform-...    already-live  already In Progress

Switch:  rex window focus -s "$REX_SESSION" GTI-401-rate-limiting-public-api
```

<!-- tmux disabled: "Attach:  tmux switch-client -t GTI-401-rate-limiting-public-api   (or `attach` from outside tmux)" -->

## Common mistakes

| Mistake | Fix |
|---|---|
| Branching from local `develop` without fetching | Always `git fetch --prune origin` first; branch from `origin/<base>`. |
| Hardcoding `develop` as the base | Read `origin/HEAD`; fall back to `develop` then `main`. Different repos differ. |
| Worktree dir under the wrong path | Use `.worktrees/<KEY>-<slug>` relative to the repo toplevel — that's the established convention here and it's gitignored. |
| Including the `<type>/` in the worktree dir name | The branch has `feat/`, the directory does not. `git worktree list` shows the existing convention. |
| Creating a branch when one already exists | The script's Step 5 conflict matrix reuses, never recreates — let it. |
| `git worktree add --force` to "fix" a path collision | Never. A pre-existing path likely has the user's work. Stop and ask. |
| Forgetting to handle remote-only branches | If `origin/$BRANCH` exists, use `-B "$BRANCH" ... origin/$BRANCH` so the new local tracks it. |
| Pushing the new branch immediately | Pushing is for commit/PR time — premature pushes create empty remote refs. |
| Inventing a ticket key when none is given | Ask the user. Don't guess. A wrong key on a branch is worse than no branch. |
| Lowercase key (`gti-273`) | Always normalize to uppercase in the branch name. |
| Hand-rolling `git worktree add` / `rex window new` | Call `start-ticket-worktree.sh`. It already gets idempotency, name sanitizing, the `ticket:<KEY>` tag, and worktree rooting right — reinventing them drifts and breaks handoff interop. |
| Renaming the current window for a multi-ticket request | That clobbers one window N times. For >1 ticket or "its own tab", use Mode B (`--session`), not Mode A's in-place rename. |
| Treating N handed keys as one Epic | The Step 2.5 Epic check is about one ticket's shape. Separate filed keys are not an umbrella — judge per key, don't fire the Epic question on the batch. |
| Renaming the active Rex window in Mode A | The user may look at a different window. Resolve the window from `$REX_BLOCK`, then rename that ID. |
| Relabeling the block in Mode A | The block label can be a `handoff:<KEY>` tag. Rename the window only. |
| Running a tmux command from a `<!-- tmux disabled -->` block | Those are kept for reference only. This user is on Rex. |
| `cd`-ing into the worktree and writing from there | The shell directory resets after every command, so the writes land in the original checkout and `/diff` stays empty. In Mode A, call `EnterWorktree`. |
| Calling `EnterWorktree` when [[handoff]] or [[worklog]] drove the run | Those open their own window or session on the worktree. Moving this session strands the caller. |
| Running `npm install` by hand after the script | The script already started the setup. Check `worktree-setup.sh <WORKTREE> --status` before you run the app. |
| Symlinking `node_modules` to the main checkout | Never. Two branches then share one `node_modules`, and bundlers follow the link to the wrong path. The setup clones or installs a separate copy. |

## Quick reference

You do Steps 1–4 (judgment) to get `KEY TYPE SLUG`; the script does the rest.

```bash
SH=~/.claude/skills/start-ticket-worktree/start-ticket-worktree.sh

# Single ticket, work in the current window (Mode A):
"$SH" GTI-273 feat project-nova            # then rename this pane's Rex window (Step 6 Mode A)

# A Rex tab per ticket (Mode B):
"$SH" GTI-273 feat project-nova --session  # → rex window focus -s "$REX_SESSION" GTI-273-project-nova

# Batch — fetch once, loop with --no-fetch:
git -C "$REPO" fetch --prune origin
"$SH" GTI-401 feat  rate-limiting-public-api --session --no-fetch
"$SH" GTI-402 fix   null-pointer-auth-token  --session --no-fetch

# Options: --session  --no-fetch  --no-setup  --base <BRANCH>  --repo <PATH>
# Exit:    0 ready · 2 bad input/not a repo · 4 path exists but not a worktree (stop, ask)

# Setup status of a worktree (Step 5.25):
"$(dirname "$SH")/worktree-setup.sh" /abs/path/.worktrees/GTI-273-project-nova --status
```
