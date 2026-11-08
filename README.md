# My Dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io/). Primarily macOS,
with occasional Windows use (nvim + wezterm).

This repo is **public**, so nothing sensitive is ever committed in plaintext.
Secrets are encrypted with [age](https://age-encryption.org/); live credentials
are pulled at runtime from 1Password and the macOS Keychain (see below).

## Machines

Config is multi-machine and branches on hostname where it matters:

Templates use `{{ includeTemplate "hostname" $ }}` to pick per-machine values.
Do not use `{{ .chezmoi.hostname }}`. chezmoi reads that value from `/etc/hosts`,
and a local override for work can change it. The partial reads `scutil --get
LocalHostName` on macOS. Per-machine values include the
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

Git and SSH auth resolve through 1Password. The 1Password service-account
tokens are not on disk. They are in the item `op-sa window` in the Private
vault. `op-sa unlock` puts them in memory for 12 hours or less. This time is
"the op-sa window".

- **`op-sa`** — runs `op` with the service-account token for the vault in the
  arguments. A service account needs no Touch ID, so use `op-sa` in scripts
  and agent tools. It cannot read the Private vault.
  - `op-sa unlock` gets both tokens with one approval in 1Password. The
    LaunchAgent `com.zaid.op-sa-window` keeps them in memory, and deletes them
    when the window closes. Each Mac has its own window.
  - If the window is closed, `op-sa` and the tools below stop at once with a
    message. They never wait for a prompt.
  - `op-sa lock` closes the window. `op-sa status` shows it. `,op-sa-health`
    checks the tokens, and finds old copies in the keychain.
- **`git-credential-op`** — git credential helper for `github.com` and
  `bitbucket.org`, with per-device item names. It reads with `op-sa`, and it
  keeps each token in the op-sa window, not in the keychain.
- **`git-sign`** — loads the SSH signing key from 1Password into the agent on
  demand, until the op-sa window closes. It starts a throwaway agent if the
  session one is unreachable. `~/.local/bin/ssh-keygen` symlinks to it (and
  `~/.local/bin` is kept ahead of `/usr/bin` in `.zshrc`) so harnesses that
  force `gpg.ssh.program=ssh-keygen` — Claude Code injects exactly that via
  `GIT_CONFIG_*` — still hit the shim.
- **SSH** — driven by the 1Password SSH agent (`private_Library/LaunchAgents`);
  `run_after_ensure-ssh-agent.sh` keeps `com.zaid.ssh-agent` loaded.
- **The `op` wrapper (`~/.local/shims/op`)** — 1Password shows the approval
  prompt on the Mac where `op` runs. If an agent on one Mac calls `op` and you
  sit at the other Mac, the wrapper runs the command on your Mac over SSH. The
  prompt then opens where you can see it. The wrapper moves only commands that
  print a secret, such as `op read` and `op item get`. All other calls run
  with no change. `~/.local/shims` is first in `PATH`, before Homebrew.
- **`twg` Bitbucket token** — all machines use one token, the `TWG.BB.API_TOKEN`
  item in the work vault. On each apply, `run_after_sync-twg-bb-token.sh`
  copies the token into `~/.config/twg/auth.conf`. The script finds the item by
  its ID, so a second item with the same title does not stop it. To rotate the
  token, change the same item, then run `chezmoi apply` on each machine. If you
  make a new item, change the ID in the script.

The age key is the only thing that you must put on a new machine by hand.
Sign in to the 1Password app, then run `op-sa unlock`. Everything else
bootstraps from them.

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
