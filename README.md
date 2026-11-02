# My Dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io/). Primarily macOS,
with occasional Windows use (nvim + wezterm).

This repo is **public**, so nothing sensitive is ever committed in plaintext.
Secrets are encrypted with [age](https://age-encryption.org/); live credentials
are pulled at runtime from 1Password and the macOS Keychain (see below).

## Machines

Config is multi-machine and branches on hostname where it matters:

Templates use `{{ .chezmoi.hostname }}` to pick per-machine values (e.g. the
LiteLLM base URL points at `localhost` over the tailnet
elsewhere), and 1Password item names are derived from each device's
`LocalHostName` (e.g. `FOO.PAT.GH`, `BAR.PAT.GH`).

## Secret handling

Two independent mechanisms, used deliberately:

- **`encrypted_*` (age).** Files prefixed `encrypted_` are stored as age
  ciphertext and decrypted on `chezmoi apply`. Used for anything with secret
  content at rest — e.g. `encrypted_dot_zshrc.age`, the work gitconfig, and the
  litellm `.env`. The age **private key is never in this repo**; it lives at
  `~/.config/chezmoi/key.txt` on each machine.
- **`private_*` (permissions only).** chezmoi's `private_` prefix only sets the
  target file to `0600` — **these files are still committed in plaintext.**
  So `private_` is used for "make it user-only on disk," never as a substitute
  for encryption. Anything secret gets `encrypted_` instead.

Config files that *reference* secrets never embed them — they use indirection:

- `os.environ/VAR` and `${VAR}` placeholders (resolved from an encrypted `.env`)
- 1Password references (`op read "op://<vault>/<item>/<field>"`)
- Keychain lookups (`security find-generic-password ...`)

## Credentials at runtime

Git and SSH auth resolve through a layered 1Password → Keychain strategy so it
works locally, over SSH, and in non-login shells:

- **`git-credential-op`** — git credential helper. Tries the local Keychain
  cache first (fast, offline, survives 1Password rate limits), then falls back
  to 1Password via a service-account token, refilling the cache. Handles
  `github.com` and `bitbucket.org`, with per-device item names.
- **`git-sign`** — loads the SSH signing key from 1Password into the agent on
  demand, standing up a throwaway agent if the session one is unreachable.
  `~/.local/bin/ssh-keygen` symlinks to it (and `~/.local/bin` is kept ahead of
  `/usr/bin` in `.zshrc`) so harnesses that force `gpg.ssh.program=ssh-keygen`
  — Claude Code injects exactly that via `GIT_CONFIG_*` — still hit the shim.
- **SSH** — driven by the 1Password SSH agent (`private_Library/LaunchAgents`);
  `run_after_ensure-ssh-agent.sh` keeps `com.zaid.ssh-agent` loaded.
- **`twg` Bitbucket token** — all machines use one token, the `TWG.BB.API_TOKEN`
  item in the work vault. On each apply, `run_after_sync-twg-bb-token.sh`
  copies the token into `~/.config/twg/auth.conf`. The script finds the item by
  its ID, so a second item with the same title does not stop it. To rotate the
  token, change the same item, then run `chezmoi apply` on each machine. If you
  make a new item, change the ID in the script.

The age key and the 1Password service-account tokens are the only things you
must place on a new machine by hand; everything else bootstraps from them.

## `ctx` — active work context

A small shell system for associating a ticket/project/topic with a directory:

- `ctx <name>` switches context (creates `~/ctx/<name>/` if needed, exports `$CTX_DIR`)
- `ctx` shows the active context; `ctx ls` lists; `ctx cd` jumps into it
- `~/.config/active-ctx` is the pointer file

## Structure

```
dot_config/     # aerospace, ghostty, wezterm, nvim, tmux, zsh, gh, private_karabiner, ...
dot_claude/     # Claude Code config, skills, hooks
dot_tmux/       # tmux config + popup scripts
private_Library/ # macOS Library bits (LaunchAgents, app support)
private_projects/ # project-scoped config (incl. work)
```

## Setup on a new machine

```bash
# 1. Install chezmoi
brew install chezmoi            # macOS
# winget install --id=twpayne.chezmoi   # Windows

# 2. Place the age key at ~/.config/chezmoi/key.txt (from your password manager)

# 3. Init + apply (prompts once for personal/work email + vault names)
chezmoi init --apply https://github.com/azaidrahman/zaid-sani-dotfiles.git
```

Preview before applying with `chezmoi diff`; edit a source file with
`chezmoi edit ~/<path>`.
