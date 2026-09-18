---
name: rename-tmux-window
description: Use when the user asks to rename, retitle, label, or set the current tmux window name — including naming it after a Jira ticket (e.g. "rename to GTI-197", "tag this window with the ticket"), naming it after what we're working on, or any explicit window title change.
---

# Rename tmux Window

Rename the tmux window this Claude session is running in. Works only inside tmux
(`$TMUX` set) — if not in tmux, say so and stop.

## 1. Decide the name

- **If the user gave a literal name**: use it verbatim, trimmed.
- **Otherwise, find a ticket key** — check user message first, then current branch:

  ```bash
  BRANCH=$(git -C "$(tmux display-message -p -t "$TMUX_PANE" '#{pane_current_path}')" rev-parse --abbrev-ref HEAD 2>/dev/null)
  TICKET=$(printf '%s' "$BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1)
  ```

  - **Ticket found** → fetch the Jira summary via `mcp__claude_ai_Atlassian__getJiraIssue` (fields: `["summary"]`), then squeeze it (see below). Format: `<KEY> <label>` (space-separated, total ≤ 25 chars).
  - **No ticket** → summarize the session into a short **2–4 word, lowercase, kebab-case** title (e.g. `tmux-window-shortcuts`).

### Label-squeezing rules (ticket names only)

Apply in order to the raw Jira summary:

1. Lowercase; strip punctuation and em/en dashes.
2. Drop fillers: `the a an of for to on in and with into from by`.
3. Drop ceremony verbs at the start: `create make setup set add build write do enable get give`.
4. Drop generic nouns when something more specific follows: `request permission access task ticket project`.
5. Keep first 2–3 *meaningful* tokens; join with `-`.
6. Hard cap: 15 chars for the label — if longer, drop the last token.

### Examples

| Ticket | Summary | Window name |
|--------|---------|-------------|
| GTI-197 | Make a jira optimizer to set timers for all tickets | `GTI-197 jira-optimizer` |
| GTI-274 | Custom domain mapping | `GTI-274 domain-mapping` |
| GTI-238 | GCP Artifact Registry — Create Docker repository for gt-odin CI/CD | `GTI-238 artifact-docker` |
| GTI-243 | Enable Claude model | `GTI-243 claude-model` |
| GTI-262 | Access to secrets for the service account | `GTI-262 secrets-sa` |

## 1b. Confirm the name (auto-derived names only)

**If the user gave a literal name in step 1, skip this — apply it directly.**

When the name was *auto-derived* (from a ticket summary or session topic — e.g.
invoked by `start-ticket-worktree`, not by an explicit "rename to X"), do not silently
apply it. Present the proposed name and let the user accept it or supply their
own, using a single `AskUserQuestion`:

- Question: `Name this window?`
- Options: the derived name (recommended, first), and one or two alternative
  squeezes if a sensible second framing exists (e.g. a different 2-3 token slug).
- The user can always pick "Other" and type a custom name — honor it verbatim,
  trimmed.

Carry the chosen name into step 2. This makes start-ticket-worktree's rename a
confirmation point rather than a silent overwrite, while leaving explicit
"rename to <X>" requests friction-free.

## 2. Apply (preserves the glyph, claims the name)

The mechanical tmux dance is scripted - pass the finished name from step 1 to:

```bash
~/.claude/skills/rename-tmux-window/rename-tmux-window.sh "<name from step 1>"
```

It prints `renamed: <glyph> <name>` on success, or exits non-zero with a message
on stderr if not in tmux. Do not hand-type the tmux commands - the script exists
to get the three easy-to-miss details right every time. What it guarantees, and why:

- **Targets `$TMUX_PANE`**, not a bare `display-message` query. The bare query
  reports the *attached client's active window* - whichever the user is looking at
  right now - not the window this Claude pane lives in. `$TMUX_PANE` is set by tmux
  to this process's own pane, so it always resolves to Claude's window. (It is
  inherited by the script, so running it from the Bash tool targets the right window.)
- **Sets `@claude_base`** to the glyph-less name. `~/.claude/hooks/notify-tmux.sh`
  re-renders the window name from this on every status event - without it the glyph
  hook reverts your name on the next event.
- **Sets `@claude_autoname_done 1`** to claim the window. On each `stop` the hook
  otherwise auto-names the window from Claude Code's conversation topic; this flag
  tells it to stand down.
- **Preserves the leading status glyph** (`●`/`⚠`/`⏸`/`✓`) if one is already present.

## 3. Confirm

Report the new name back (e.g. `Renamed window → ● GTI-197 jira-optimizer`).

## Common mistakes

The three tmux-plumbing pitfalls (skipping `@claude_base` / `@claude_autoname_done`,
or targeting the wrong window) are handled by the script in step 2 - don't re-type
those commands by hand. The mistakes left to you are in *deciding the name*:

- **Re-typing the tmux commands instead of calling the script** — reintroduces the
  exact pitfalls the script exists to prevent.
- **Using the raw Jira summary verbatim** — 60-char summaries defeat status-bar readability; always squeeze.
- **Keeping ceremony verbs** (`create`, `make`, `setup`) — strip them; they appear in 80% of summaries and carry no signal.
