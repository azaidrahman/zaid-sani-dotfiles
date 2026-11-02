#!/usr/bin/env bash
# Tests for prefix+y in Rex: scripts/commit-draft.sh, commit_draft.lua and
# dock.lua.
#
# A stub replaces the editor of the tmux script, so no nvim opens. The stub
# records its arguments and its directory in stub.log. The Rex tests start a
# separate Rex server on a socket of their own, so they never touch the live
# server. Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REX_DIR="$ROOT/dot_config/rex"
GATE="$REX_DIR/scripts/executable_commit-draft.sh"
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
TMP=$(mktemp -d /tmp/rexcd.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

# If the file "hold" exists, the stub waits, so that its pane stays open.
STUB="$TMP/stub.sh"
cat >"$STUB" <<'EOF'
#!/bin/bash
dir=$(dirname "$0")
echo "$1 $(basename "$2") $(basename "$PWD")" >>"$dir/stub.log"
if [ -e "$dir/hold" ]; then sleep 20; fi
EOF
chmod +x "$STUB"

REPO="$TMP/repo"
mkdir -p "$TMP/plain"
git init -q "$REPO"
GIT_DIR=$(git -C "$REPO" rev-parse --absolute-git-dir)
MSG="$GIT_DIR/CLAUDE_COMMIT_MSG"
PR="$GIT_DIR/CLAUDE_PR_MSG"

# drafts NAMES — keep only the drafts in NAMES (commit, pr).
drafts() {
	rm -f "$MSG" "$PR"
	case " $* " in *" commit "*) echo "fix: a thing" >"$MSG" ;; esac
	case " $* " in *" pr "*) printf 'Title\n\nBody\n' >"$PR" ;; esac
}

# gate KEYS DIR — run the gate with KEYS as input. Print the stub call, or the
# first line that the gate shows.
gate() {
	: >"$TMP/stub.log"
	printf '%s' "$1" | COMMIT_MSG_POPUP="$STUB" bash "$GATE" "$2" >"$TMP/out" 2>&1
	if [ -s "$TMP/stub.log" ]; then
		cat "$TMP/stub.log"
	else
		grep -m 1 . "$TMP/out" | sed 's/^ *//'
	fi
}

# The gate. Columns: label | drafts | keys | dir | expected.
while IFS='|' read -r label names keys dir want; do
	# shellcheck disable=SC2086 # names is a list of words
	drafts $names
	check "gate: $label" "$want" "$(gate "$keys" "$dir")"
done <<EOF
not a git repo|||$TMP/plain|Not a git repo: $TMP/plain
no draft|||$REPO|No commit message or pull request draft in repo.
commit draft only|commit||$REPO|--edit CLAUDE_COMMIT_MSG repo
pull request draft only|pr||$REPO|--edit-pr CLAUDE_PR_MSG repo
both drafts, key p|commit pr|p|$REPO|--edit-pr CLAUDE_PR_MSG repo
both drafts, other key|commit pr|q|$REPO|Edit which draft?
EOF

# The float and the dock, on a separate Rex server.
unset REX_SESSION REX_BLOCK REX_CLIENT
export REX_SERVER="unix://$TMP/rex.sock"
# The float runs the gate as a program. In the source tree, the gate has no
# execute bit (chezmoi sets it when it deploys the file), so use a copy.
cp "$GATE" "$TMP/commit-draft.sh"
chmod +x "$TMP/commit-draft.sh"
export REX_COMMIT_DRAFT="$TMP/commit-draft.sh" COMMIT_MSG_POPUP="$STUB"
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("commit_draft")\nrequire("dock")\n' \
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
has_cwd() { rex --autostart=false block call -s "$sid" -b "$opener" process | jq -e '.foreground.cwd'; }
stub_called() { grep -q . "$TMP/stub.log"; }

drafts commit
: >"$TMP/stub.log"
touch "$TMP/hold"
sid=$(rex --autostart=false new cd-test -c "$REPO" --json | jq -r '.session_id')
opener=$(view | jq -r '.windows[0].focused_block_id')
# A larger pane on the right. The dock must use the opener, not this pane.
rex --autostart=false split -s "$sid" -b "$opener" --split=right --ratio 70 --focus=false -c "$TMP" >/dev/null
wait_for "the shell of the opener starts" has_cwd

rex --autostart=false do commit_draft -s "$sid" >/dev/null
float=$(view | jq -r '[.windows[0].layers[] | select(.kind == "floating") | .blocks[].block_id] | join(" ")')
wait_for "the float runs the editor" stub_called ||
	rex --autostart=false capture -s "$sid" -b "$float" --trim >&2
check "float: runs the editor in the directory of the pane" \
	"--edit CLAUDE_COMMIT_MSG repo" "$(cat "$TMP/stub.log")"
check "float: the focused pane is the float" "$float" "$(view | jq -r '.windows[0].focused_block_id')"

rex --autostart=false do dock_float -s "$sid" >/dev/null
check "dock: the float is on the right of the opener" "$opener $float" \
	"$(view | jq -r --arg o "$opener" '.. | objects | select(.split?.before.block_id? == $o) | "\(.split.before.block_id) \(.split.after.block_id)"')"
check "dock: no floating layer is left, and the pane keeps focus" "0 $float" \
	"$(view | jq -r '"\([.windows[0].layers[] | select(.kind == "floating")] | length) \(.windows[0].focused_block_id)"')"

exit $fail
