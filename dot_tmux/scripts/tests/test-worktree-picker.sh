#!/usr/bin/env bash
# Tests for the cd of the prefix+e worktree picker (worktree-picker.sh).
#
# A stub tmux replaces tmux, so no tmux server runs. The stub says that zsh
# owns the pane, and records each send-keys. Stubs also replace fzf and
# tuicr. The fzf stub prints the row of the path in FZF_PICK. Run with bash.
set -u

# Source-tree names carry the chezmoi `executable_` prefix.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PICKER="$script_dir/executable_worktree-picker.sh"

fail=0
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   - %s\n' "$1"
	else
		printf 'FAIL - %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat >"$TMP/bin/tmux" <<EOF
#!/bin/bash
case "\$1" in
display-message) [ "\$2" = -p ] && echo zsh ;;
send-keys) echo "\$*" >>"$TMP/send.log" ;;
esac
EOF
cat >"$TMP/bin/fzf" <<'EOF'
#!/bin/bash
awk -F '\t' -v p="$FZF_PICK" '$3 == p'
EOF
printf '#!/bin/bash\n' >"$TMP/bin/tuicr"
chmod +x "$TMP/bin/tmux" "$TMP/bin/fzf" "$TMP/bin/tuicr"
export PATH="$TMP/bin:$PATH"

git init -q "$TMP/repo"
git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
B="$TMP/repo/.worktrees/b"
Q="$TMP/repo/.worktrees/it's"
E="$TMP/repo/.worktrees/café"
git -C "$TMP/repo" worktree add -q -b b "$B"
git -C "$TMP/repo" worktree add -q -b q "$Q"
git -C "$TMP/repo" worktree add -q -b e "$E"

# The cd. Columns: label | fzf pick | expected send-keys calls, joined by ";".
# The é path shows that the guard is an allowlist: the bytes of é are not
# control characters.
while IFS='|' read -r label pick want; do
	: >"$TMP/send.log"
	(cd "$TMP/repo" && FZF_PICK=$pick bash "$PICKER" %1 </dev/null >/dev/null 2>&1)
	check "cd: $label" "$want" "$(paste -sd ';' "$TMP/send.log")"
done <<EOF
a plain path|$B|send-keys -t %1 -l cd -- '$B';send-keys -t %1 C-m
a path with a quote|$Q|
a path with é|$E|
EOF

exit $fail
