# Chezmoi Dotfiles

## Active work context

The user uses a `ctx` system to associate a work context (ticket, project, or topic) with a local directory.

- **`~/.config/active-ctx`** — plain text file containing the current context name (e.g. `GTI-197` or `chezmoi-refactor`)
- **`~/ctx/<name>/`** — the context directory; may contain HTML research artifacts, notes, data, or anything else
- **`$CTX_DIR`** — env var set in every shell pointing to the active context directory

Do NOT load, scan, or summarize the active context at session start. It is lazy/on-demand only. The active context directory is already available in the `$CTX_DIR` env var — use that directly instead of reading `~/.config/active-ctx` or listing `~/ctx/*`. Only when the user explicitly asks (e.g. "look at my research", "check my context") should you read from `$CTX_DIR`. When saving HTML artifacts for the user, write them to `$CTX_DIR` (or `~/ctx/<name>/` if `$CTX_DIR` isn't set).

## Shell functions

- `ctx <name>` — switch to a context (creates `~/ctx/<name>/` if needed, sets `$CTX_DIR`)
- `ctx` — show active context
- `ctx ls` — list all contexts
- `ctx cd` — cd into `$CTX_DIR`
