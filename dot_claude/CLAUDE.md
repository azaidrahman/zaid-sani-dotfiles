@~/.agents/AGENTS.md

# Claude Code only

The file above holds the rules for all agent tools. Claude Code, Codex, omp,
and pi read the same file. Put a rule here only if it applies to Claude Code
alone.

## Move the session into a worktree

After you create a worktree, move the session into it. Use the
`EnterWorktree` tool with the path that the skill reports.

A `cd` command does not move the session. The session stays in the old
directory. The `/diff` panel then shows no changes, because it reads the
repository of the session directory.

Skip this step if the skill opened a new tmux session or window in the
worktree. That session already has the correct directory.
