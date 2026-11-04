---
name: aerospace
description: Use when working with this Mac's AeroSpace tiling window manager config — making an app float / keep its own size instead of being tiled, "ignoring" an app from tiling, assigning an app to a workspace, or otherwise editing aerospace.toml. Symptoms include "make X float", "stop AeroSpace resizing X", "add X to the ignore/float list", "keep X its own size", "move X to workspace N", or editing aerospace.toml.
---

# AeroSpace window rules

AeroSpace is this Mac's tiling window manager. There is **no separate "ignore" list** — the way to make an app keep its own size (not be tiled/resized) is to give it `layout floating` via an `[[on-window-detected]]` rule. That is the same mechanism used to move an app to a workspace.

## The one rule that prevents breakage

**Edit the chezmoi source, not the deployed file.** A plain edit to `~/.config/aerospace/aerospace.toml` is overwritten by the next `chezmoi apply`.

- **Edit here (chezmoi source):** `~/.local/share/chezmoi/dot_config/aerospace/aerospace.toml`
- **Deployed (aerospace reads this):** `~/.config/aerospace/aerospace.toml`

## Make an app float ("ignore" / keep its own size)

Add (or extend) an `[[on-window-detected]]` block. Put float-only rules in the `# Floating` section near the top of the file, alongside finder / FreeTube / 1Password / Todoist.

```toml
[[on-window-detected]]
if.app-id = 'info.sioyek.sioyek'
run = 'layout floating'
```

**Prefer `if.app-id`** (the macOS bundle id) — it's exact and stable. Use `if.app-name-regex-substring = 'IINA'` only when you don't have the id or want a loose match.

**Combine float + workspace** by making `run` a list (order: float first, like the ghostty rule):

```toml
[[on-window-detected]]
if.app-name-regex-substring = 'IINA'
run = [
    'layout floating',
    'move-node-to-workspace 6',
]
```

## Find the app-id or exact name

The app must be running. List running apps (pid | bundle-id | name):

```bash
aerospace list-apps          # human-readable table
aerospace list-apps --json   # app-bundle-id / app-name / app-pid
```

Copy the `app-bundle-id` into `if.app-id`, or the `app-name` into `if.app-name-regex-substring`.

## Deploy chain

```bash
chezmoi diff ~/.config/aerospace/aerospace.toml      # review
chezmoi apply ~/.config/aerospace/aerospace.toml     # deploy ONLY the aerospace file
aerospace reload-config                              # make the config live
```

**Scope the apply to the aerospace file.** A bare `chezmoi apply` can trigger unrelated `run_onchange` scripts (e.g. brew-bundle) that prompt on a TTY and fail in a non-interactive/agent session.

**`on-window-detected` rules only fire on *newly detected* windows.** After reloading, an already-open window won't float until re-detected:
- Relaunch the app (or close/reopen its window), **or**
- Focus the window and run `aerospace layout floating` to float it immediately.

## Workspace map (from the config)

| WS | Purpose |
|----|---------|
| 1 | Left monitor: terminal / apps |
| 2 | Left monitor: work browser / work apps |
| 3 | Left monitor: free |
| 4 | Left monitor: free |
| 5 | Right monitor: personal / secondary browser |
| 6 | Right monitor: secondary apps |
| 7 | Right monitor: main / blank (place to do splits) |

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Edited `~/.config/aerospace/aerospace.toml` directly | Revert — edit the chezmoi source, then `chezmoi apply` |
| Looked for an "ignore" list | There isn't one; use `run = 'layout floating'` |
| Change didn't take effect | Run `aerospace reload-config`, then relaunch the app (rules only fire on new windows) |
| Already-open window still tiled | Focus it and run `aerospace layout floating` |
| Bare `chezmoi apply` hung/failed | Scope it: `chezmoi apply ~/.config/aerospace/aerospace.toml` |
| Guessed the app name | Run `aerospace list-apps` to get the exact name / bundle id |
