---
name: start-worktree
description: Use when non-trivial work has no Jira ticket. Create an isolated branch and worktree before writing. Use for personal configuration, multi-file changes, tests, refactors, and features without a ticket.
---

# Start ticketless work

Use this skill for work without a Jira ticket. Do not create a fake ticket.

`agent-worktree` creates or reuses a branch named `<type>/<slug>`. It creates the worktree at `.worktrees/<slug>`. The command locks the repository while it fetches and creates the worktree.

## Choose the branch name

Use one type from this list:

- `feat` for a new user-visible capability.
- `fix` for a defect correction.
- `chore` for configuration, maintenance, or internal work.
- `docs` for documentation only.

Create a lowercase kebab-case slug. Keep it specific and 30 characters or less.

Examples:

```text
chore/omp-worktree-defaults
chore/chezmoi-agent-policy
fix/tmux-session-cleanup
```

## Create the worktree

Run this command before the first write:

```bash
agent-worktree <type> <slug>
```

For a new Claude Code or OMP session in tmux, run one of these commands:

```bash
agent-worktree <type> <slug> --session claude
agent-worktree <type> <slug> --session omp
```

The command reports the branch and absolute worktree path. Use the new session or path for all writes. Do not continue writing in the original checkout.

If the command returns exit code 4, stop. The path exists but is not the expected worktree. Do not overwrite or remove it.

## Move the session into the worktree

Run this step when you did not use `--session`. The session still works in the original checkout.

Call the `EnterWorktree` tool with the reported path:

```text
EnterWorktree path=/abs/path/to/repo/.worktrees/<slug>
```

A `cd` command does not move the session. The shell directory returns to the original checkout after each command. The session then writes to the wrong tree, and the `/diff` panel shows no changes.

Skip this step when you used `--session claude` or `--session omp`. That new session already starts in the worktree.

To leave the worktree in the same session, call `ExitWorktree` with `action: keep`. This tool never deletes a worktree that `agent-worktree` created.

## Concurrent agents

One primary writing session owns this worktree. Do not send two writing agents to it.

If agents must write concurrently, use isolated task worktrees. Integrate their changes only after each agent finishes.

## Finish the work

Use `finish-branch` after the branch lands. It supports branches with no ticket. It skips the Jira transition when no ticket key exists.
