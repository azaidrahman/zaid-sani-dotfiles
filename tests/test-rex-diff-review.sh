#!/usr/bin/env bash
# Tests for prefix+e in Rex: scripts/diff-review.sh and diff_review.lua.
#
# Stubs replace tuicr and fzf. The tuicr stub records its arguments and its
# directory in tuicr.log. The fzf stub prints the row of the path in
# FZF_PICK, or exits 130 (Esc) if FZF_PICK is empty. The Rex tests start a
# separate Rex server on a socket of their own, so they never touch the live
# server. Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REX_DIR="$ROOT/dot_config/rex"
GATE="$REX_DIR/scripts/executable_diff-review.sh"
export WORKTREE_PICKER="$ROOT/dot_tmux/scripts/executable_worktree-picker.sh"
fail=0
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   - %s\n' "$1"
	else
		printf 'FAIL - %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

# The path of a Unix socket must be short, so do not use $TMPDIR.
TMP=$(mktemp -d /tmp/rexdr.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/plain"
cat >"$TMP/bin/tuicr" <<EOF
#!/bin/bash
echo "tuicr \$* \$(basename "\$PWD")" >>"$TMP/tuicr.log"
EOF
cat >"$TMP/bin/fzf" <<'EOF'
#!/bin/bash
[ -n "${FZF_PICK:-}" ] || exit 130
awk -F '\t' -v p="$FZF_PICK" '$3 == p'
EOF
chmod +x "$TMP/bin/tuicr" "$TMP/bin/fzf"
export PATH="$TMP/bin:$PATH"

# solo: a repo with one worktree. repo: a repo with a second worktree, b.
for r in solo repo; do
	git init -q "$TMP/$r"
	git -C "$TMP/$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
B="$TMP/repo/.worktrees/b"
git -C "$TMP/repo" worktree add -q -b b "$B"

# dirty DIRS — give a change to each dir in DIRS, and none to the others.
dirty() {
	rm -f "$TMP/solo/new" "$TMP/repo/new" "$B/new"
	local d
	for d in "$@"; do touch "$d/new"; done
}

# gate DIR — run the gate in DIR. Print the tuicr call, or the first line that
# the gate shows.
gate() {
	: >"$TMP/tuicr.log"
	bash "$GATE" "$1" </dev/null >"$TMP/out" 2>&1
	if [ -s "$TMP/tuicr.log" ]; then
		cat "$TMP/tuicr.log"
	else
		grep -m 1 . "$TMP/out" | sed 's/^ *//'
	fi
}

# The gate. Columns: label | dirty dirs | fzf pick | dir | expected.
while IFS='|' read -r label dirs pick dir want; do
	# shellcheck disable=SC2086 # dirs is a list of words
	dirty $dirs
	check "gate: $label" "$want" "$(FZF_PICK=$pick gate "$dir")"
done <<EOF
not a git repo|||$TMP/plain|Not a git repo: $TMP/plain
one worktree, no changes|||$TMP/solo|No changes in solo.
one worktree, changes|$TMP/solo||$TMP/solo|tuicr -w solo
two worktrees, Esc|$B||$TMP/repo|
two worktrees, pick a clean one|$TMP/repo|$B|$TMP/repo|No changes in b.
two worktrees, pick a dirty one|$B|$B|$TMP/repo|tuicr -w b
EOF

# A path with a character that is not on the allowlist is not typed into the
# shell. The é path shows that the guard is an allowlist: the bytes of é are
# not control characters. A stub rex says that zsh owns the pane, and records
# each send.
Q="$TMP/repo/.worktrees/it's"
E="$TMP/repo/.worktrees/café"
git -C "$TMP/repo" worktree add -q -b q "$Q"
git -C "$TMP/repo" worktree add -q -b e "$E"
mkdir -p "$TMP/fakerex"
cat >"$TMP/fakerex/rex" <<EOF
#!/bin/bash
case "\$*" in
*process*) echo '{"foreground":{"name":"zsh"}}' ;;
*send*) echo "\$*" >>"$TMP/send.log" ;;
esac
EOF
chmod +x "$TMP/fakerex/rex"
for label in "a quote:$Q" "é:$E"; do
	path=${label#*:}
	touch "$path/new"
	: >"$TMP/send.log"
	PATH="$TMP/fakerex:$PATH" FZF_PICK=$path bash "$GATE" "$TMP/repo" s1 b1 </dev/null >/dev/null 2>&1
	check "gate: no cd for a path with ${label%%:*}" "" "$(cat "$TMP/send.log")"
done

# The float and the cd, on a separate Rex server.
unset REX_SESSION REX_BLOCK REX_CLIENT
export REX_SERVER="unix://$TMP/rex.sock"
# A stub gate records its arguments and its directory, then waits, so that the
# float stays open. The float gets the environment of the server.
cat >"$TMP/gate.sh" <<EOF
#!/bin/bash
echo "\$* \$PWD" >"$TMP/gate.log"
sleep 20
EOF
chmod +x "$TMP/gate.sh"
export REX_DIFF_REVIEW="$TMP/gate.sh"
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("diff_review")\n' \
	"$REX_DIR" >"$TMP/init.lua"
rex server run --listen "$REX_SERVER" --state-dir "$TMP/server" --restore=false \
	--config "$TMP/init.lua" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do rex --autostart=false api call session.list '{}' >/dev/null 2>&1 && break; sleep 0.1; done
if [ "$(rex --autostart=false api call session.list '{}' | jq '.sessions | length')" != 0 ]; then
	echo "the test server has sessions, so it can be the live server" >&2
	exit 1
fi

# wait_for DESCRIPTION COMMAND... — run COMMAND until it succeeds, for 10s.
wait_for() {
	local what=$1 _
	shift
	for _ in $(seq 1 100); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
	echo "timeout: $what" >&2
	return 1
}
view() { rex --autostart=false api call -s "$sid" session.view '{}'; }
opener_cwd() { rex --autostart=false block call -s "$sid" -b "$opener" process | jq -r '.foreground.cwd // empty'; }
opener_in() { [ "$(opener_cwd)" = "$1" ]; }
gate_called() { [ -s "$TMP/gate.log" ]; }

sid=$(rex --autostart=false new dr-test -c "$TMP/repo" --json | jq -r '.session_id')
opener=$(view | jq -r '.windows[0].focused_block_id')
wait_for "the shell of the opener starts" opener_in "$TMP/repo"

rex --autostart=false do diff_review -s "$sid" >/dev/null
float=$(view | jq -r '[.windows[0].layers[] | select(.kind == "floating") | .blocks[].block_id] | join(" ")')
wait_for "the float runs the gate" gate_called
check "float: runs the gate with the pane path, the session and the pane" \
	"$TMP/repo $sid $opener $TMP/repo" "$(cat "$TMP/gate.log")"
check "float: the float has focus" "$float" "$(view | jq -r '.windows[0].focused_block_id')"

# The real gate types `cd` into the shell of the opener.
dirty "$B"
FZF_PICK=$B bash "$GATE" "$TMP/repo" "$sid" "$opener" </dev/null >/dev/null 2>&1
wait_for "the opener changes to the worktree" opener_in "$B"
check "cd: the shell of the opener is in the picked worktree" "$B" "$(opener_cwd)"

exit $fail
