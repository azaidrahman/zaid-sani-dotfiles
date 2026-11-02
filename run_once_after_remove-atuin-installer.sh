#!/bin/bash
# Remove the copy of atuin that the atuin installer made.
#
# Homebrew installs atuin now (see the Brewfile). The old installer put a
# binary in ~/.atuin/bin, and it added a line to ~/.profile that puts the
# binary on PATH. A second binary can start a daemon of a different version.
# Each client restarts a daemon that has a different version, so the two
# binaries stop each other.
#
# Keep ~/.atuin/logs. The daemon writes its logs there, also when Homebrew
# installs it.
set -euo pipefail

if [ ! -d "$HOME/.atuin/bin" ]; then
    exit 0
fi

# If Homebrew did not install atuin, the shells need the copy of the
# installer. Fail, so that chezmoi runs this script again on the next apply.
if [ ! -x /opt/homebrew/bin/atuin ]; then
    echo "atuin: install atuin with Homebrew first (brew install atuin)." >&2
    echo "atuin: ~/.atuin/bin stays until then." >&2
    exit 1
fi

# Remove the line that sources ~/.atuin/bin/env. If the env file is missing,
# a POSIX login shell stops at that line.
# The line has a literal $HOME, so do not expand it here.
# shellcheck disable=SC2016
envline='. "$HOME/.atuin/bin/env"'
for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ ! -f "$rc" ] || ! grep -qxF "$envline" "$rc"; then
        continue
    fi
    tmp="$(mktemp)"
    # The installer writes the line with an empty line before it. Remove both,
    # so that the file keeps its own shape.
    awk -v target="$envline" '
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (line[i] == target) {
                    if (n > 0 && out[n] == "") { n-- }
                    continue
                }
                out[++n] = line[i]
            }
            for (i = 1; i <= n; i++) { print out[i] }
        }
    ' "$rc" > "$tmp"
    cat "$tmp" > "$rc"
    rm -f "$tmp"
done

rm -rf "$HOME/.atuin/bin"
