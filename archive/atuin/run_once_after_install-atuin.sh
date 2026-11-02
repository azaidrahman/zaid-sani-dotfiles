#!/bin/bash
# Install atuin, which keeps the shell history in a SQLite database.
#
# Atuin is not in the Brewfile on purpose. The project ships its own installer
# and its own `atuin update` command, so Homebrew does not manage it.
#
# The installer appends `eval "$(atuin init zsh)"` to ~/.zshrc, and it gives no
# flag to stop this (setup.atuin.sh, line 59). Chezmoi owns ~/.zshrc, and the
# shell setup lives in .config/zsh/plugins.zsh. Remove the appended lines again
# at the end, so that ~/.zshrc stays equal to the chezmoi source.
set -euo pipefail

if [ ! -x "$HOME/.atuin/bin/atuin" ]; then
    curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
fi

zshrc="${ZDOTDIR:-$HOME}/.zshrc"
if [ -f "$zshrc" ] && grep -q 'atuin init zsh' "$zshrc"; then
    tmp="$(mktemp)"
    # The installer writes each line with a leading newline. Remove each line
    # and the blank line in front of it, so that the file keeps its own shape.
    awk -v t1='eval "$(atuin init zsh)"' -v t2='. "$HOME/.atuin/bin/env"' '
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (line[i] == t1 || line[i] == t2) {
                    if (n > 0 && out[n] == "") { n-- }
                    continue
                }
                out[++n] = line[i]
            }
            for (i = 1; i <= n; i++) { print out[i] }
        }
    ' "$zshrc" > "$tmp"
    cat "$tmp" > "$zshrc"
    rm -f "$tmp"
fi
