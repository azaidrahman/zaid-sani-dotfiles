# Chezmoi dotfiles

This file holds the rules for work in this repository. The rules for all
repositories are in `dot_agents/AGENTS.md`. Chezmoi deploys that file to
`~/.agents/AGENTS.md`.

Chezmoi does not deploy this file. `.chezmoiignore` lists it.

## This repository is public

This repository pushes to a public GitHub repository. Each committed file is
visible to all people.

Do not commit company values in plain text. This includes organization IDs,
project IDs, internal email addresses, group names, custom role names, and
host names. Use one of these options, in this order:

1. Find the value at run time. For example, read the GCP organization from
   `gcloud organizations list`.
2. Write the generated file outside the repository, under
   `${XDG_DATA_HOME:-~/.local/share}/`, with mode 0600.
3. If you must commit the value, encrypt it with chezmoi age encryption. Use
   the `encrypted_` prefix.

Before you commit, examine the diff for company values.

## Tests for tmux

Do not run a command that kills, moves, or switches tmux objects on the live
tmux server. The live server holds real work, and a wrong argument destroys
it.

- Test tmux code on a separate server: `tmux -L <socket>`. For an example, see
  `dot_tmux/scripts/tests/test-tmux-zen-layout.sh`.
- If a check on the live server is necessary, only create and read objects.
  Replace each function that kills, moves, or switches with a stub. Remove
  the objects that you made.
- Run test scripts with `bash`, not with zsh.
- In the code, run a destructive command only on an object that the code owns.
  For example, zen mode sets the `@zen_owned` option.

## Retired configuration

Do not delete old configuration. Move it to `archive/`, or to the archive
directory of the tool. For example, disabled nvim plugins go to
`lua/zaid/plugins_archive/`. Chezmoi does not deploy `archive/`.

If a target file must go away from the home directory, add its path to
`.chezmoiremove`.
