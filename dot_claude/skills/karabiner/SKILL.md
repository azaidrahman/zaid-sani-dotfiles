---
name: karabiner
description: Use when working with this Mac's Karabiner-Elements / Goku keyboard config — adding, changing, removing, or inspecting key bindings, app-launcher shortcuts, hyper-key navigation, shortcut layers (l1/l2/l3), or aerospace workspace keys. Symptoms include "remap a key", "make X open Y", "add a karabiner shortcut/hotkey", editing karabiner.edn or karabiner.json, or running goku.
---

# Karabiner (Goku) keymaps

This Mac's keyboard remapping runs on **Karabiner-Elements**, but you almost never touch Karabiner's JSON. The config is **generated** by [Goku](https://github.com/yqrashawn/GokuRakuJoudo) from EDN, and the EDN's bulk is generated from **YAML configs** by a Python build step. There is also a purpose-built **`add-keymap` CLI** for adding/editing bindings.

## The one rule that prevents breakage

**Never hand-edit `karabiner.json` or `karabiner.edn`.** Both are generated; your edits are overwritten on the next build. To change a binding you either:
- run the **`add-keymap`** CLI (preferred), or
- edit the **YAML config** for that layer (or `karabiner.base.edn` for hand-written rules), then rebuild.

**Violating the letter of this rule is breaking the config — the next `./build.sh` silently discards anything you put in a generated file or between `;; BEGIN … ;; END` markers.**

## Where things live

- **Edit here (chezmoi source):** `~/.local/share/chezmoi/dot_config/private_karabiner/`
- **Deployed (read-only, goku reads this):** `~/.config/karabiner/`

Always edit in the chezmoi source, then deploy. Don't edit `~/.config/karabiner/` directly.

## Layer map

| Layer | Hold to activate | Source file | Entry format |
|-------|------------------|-------------|--------------|
| **App launcher** | Right Option | `config/app.yaml` → `app:` | `key \| label \| App Name` (or `!gokuCombo`); UPPERCASE key = shift variant |
| **Workspace** (aerospace) | Left Option | `config/help-text.yaml` → `workspace:` / `workspace-shift:` | `key \| label \| aerospace command` |
| **Shortcut l1** | Left Shift + Right Option | `config/shortcuts.yaml` → `l1:` | `key \| label \| open:App` or `!gokuCombo` (omit 3rd field → auto F-key) |
| **Shortcut l2** | Left Ctrl + Right Option | `config/shortcuts.yaml` → `l2:` | same as l1 |
| **Shortcut l3** | Left Command + Right Option | `config/shortcuts.yaml` → `l3:` | same as l1 |
| **Hyper** (vim nav) | CapsLock | `config/hyperkeys.yaml` | declarative `key: {-: action, modifier: action}` |
| **Hand-written rules** (caps→hyper, Tab→Ctrl, double-tap, layer triggers) | — | `karabiner.base.edn` (outside `BEGIN/END` markers) | raw Goku EDN |

> The README's claim that the app launcher lives in `help-text.yaml` is **stale** — it's `app.yaml`. `help-text.yaml` holds only the workspace layer.

## Keyboard Maestro hotkeys in the help

A Keyboard Maestro macro can own a hotkey directly, for example snapcal on hyper+d. No file in this directory declares that hotkey. The build reads it from `dot_config/keyboardmaestro/exact_macros/*.kmmacros` (`lib/kmhotkeys.py`) and puts it in the help:

- cmd+ctrl+opt+shift + key: the Hyper layer, the same as a `hyperkeys.yaml` key. It needs no rule, because CapsLock held already sends those four modifiers.
- F13 to F20: no new row. The row of the shortcut layer that sends the F-key shows it.
- Any other combo: the extras list.

Do not mirror a macro hotkey in `extras.yaml` or `hyperkeys.yaml`. Do not add a rule that sends the same key back. The build stops with `error: Keyboard Maestro hotkeys` in two cases:

- A Karabiner rule takes a hyper hotkey, so the macro never fires.
- No shortcut layer sends an F-key hotkey.

For the full steps, see "Hotkeys and the help HUD" in the keyboard-maestro skill.

**Verify what the person sees.** After a change to the help, open the HUD (caps+?) or the hyper overlay (hold caps, push /) and find the key. A correct line in `data/keymap-index.tsv` can still show in the wrong place. For example, an extras line `⇪d` shows as a raw combo in the list, not on the Hyper board.

## Goku modifier legend

| Code | Modifier | Code | Modifier | | Symbol | Meaning |
|------|----------|------|----------|---|--------|---------|
| `C` | left_command | `Q` | right_command | | `!` | mandatory modifier |
| `T` | left_control | `W` | right_control | | `#` | optional modifier |
| `O` | left_option | `E` | right_option | | `##` | optional any |
| `S` | left_shift | `R` | right_shift | | `!QWER` | right-hyper (cmd+ctrl+opt+shift) |
| `F` | fn | `P` | caps_lock | | | |

Symbol keys use names, not the glyph: `hyphen = equal_sign [ open_bracket ] close_bracket ; semicolon ' quote , comma . period / slash \ backslash \` grave_accent_and_tilde space spacebar`.

## Deploy chain

```bash
cd ~/.local/share/chezmoi/dot_config/private_karabiner
./build.sh                                                          # regenerate karabiner.edn from YAML
chezmoi apply ~/.config/karabiner                                   # deploy ONLY the karabiner subtree
GOKU_EDN_CONFIG_FILE="$HOME/.config/karabiner/karabiner.edn" goku   # recompile karabiner.json
grep '<AppOrKey>' ~/.config/karabiner/karabiner.json               # VERIFY it compiled
```

**Karabiner loads `karabiner.json`, which only `goku` produces — the binding isn't live until goku runs.** Don't trust the `run_onchange_after_goku` hook to do it: it's hash-gated and can be skipped (before 2026-11-10 it was `run_onchange_goku`, which ran *before* chezmoi wrote the new edn and compiled the stale one), leaving a correct-looking `karabiner.edn` but an un-recompiled `.json`. Always run `goku` explicitly and verify the `.json`.

**Scope the apply to `~/.config/karabiner`.** A bare `chezmoi apply` — and the `add-keymap` CLI's `-deploy` — runs a *global* apply that can trigger unrelated `run_onchange` scripts (e.g. `brew-bundle`) which prompt on a TTY and **fail in a non-interactive/agent session**, aborting before goku. If you do use `-deploy` and it errors on another script, finish with the explicit `goku` line above and verify.

## What do you need to do?

- **Add / change / remove a binding** → read `references/add-keymap.md`. Prefer the `add-keymap` CLI's one-liner mode.
- **See what's currently bound, find a free key, or explain a binding** → read `references/discovering.md`.
- **Understand the build pipeline, troubleshoot "my change didn't take effect", add a whole new layer, or rebuild the CLI** → read `references/architecture.md`.

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Edited `karabiner.edn` or `karabiner.json` | Revert — edit the YAML (or `base.edn`) instead, then `./build.sh` |
| Edited inside `;; BEGIN … ;; END` markers | That block is regenerated; edit the YAML source instead |
| Ran `goku` but the change didn't take | You edited the chezmoi source — run `./build.sh && chezmoi apply` first (goku reads the deployed path) |
| Put the app launcher in `help-text.yaml` | App launcher is `app.yaml`; `help-text.yaml` is workspace only |
| Used a glyph like `[` in EDN | Use the key name `open_bracket` |
| Added a Keyboard Maestro hotkey to `extras.yaml`, or a pass-through rule to `hyperkeys.yaml` | Remove it. The build reads macro hotkeys from the macro files. See "Keyboard Maestro hotkeys in the help" |
