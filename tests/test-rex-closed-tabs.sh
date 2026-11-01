#!/usr/bin/env bash
# Tests for the closed tabs of Rex: closed-tabs-watcher.lua and closed-tabs.sh.
#
# The tests start a separate Rex server on a socket of their own, with an
# empty configuration, so they never touch the live server or its log. A fake
# `claude` stands in for Claude. It is a small C program, because macOS stops
# a copy of a system program such as sleep. Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHER="$ROOT/dot_config/rex/scripts/closed-tabs-watcher.lua"
SCRIPT="$ROOT/dot_config/rex/scripts/executable_closed-tabs.sh"
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
TMP=$(mktemp -d /tmp/rexct.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
SERVER_PID="" WATCHER_PID=""
cleanup() {
	[ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

unset REX_SESSION REX_BLOCK REX_CLIENT REX_CLOSED_CLIENT
export REX_SERVER="unix://$TMP/rex.sock"
export REX_CLOSED_DIR="$TMP/state"
mkdir -p "$TMP/bin" "$TMP/sessions" "$TMP/projects" "$TMP/a" "$TMP/b" "$TMP/state"
printf '#include <unistd.h>\nint main(void) { for (;;) pause(); }\n' >"$TMP/claude.c"
cc -o "$TMP/bin/claude" "$TMP/claude.c" || exit 1
: >"$TMP/init.lua"

rex server run --listen "$REX_SERVER" --state-dir "$TMP/server" --restore=false \
	--config "$TMP/init.lua" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do rex --autostart=false api call session.list '{}' >/dev/null 2>&1 && break; sleep 0.1; done

rex --autostart=false do --all "$WATCHER" label=test state="$TMP/state" interval=1 \
	claude_sessions="$TMP/sessions" claude_projects="$TMP/projects" >"$TMP/watcher.log" 2>&1 &
WATCHER_PID=$!

# wait_for DESCRIPTION COMMAND... — run COMMAND until it succeeds, for 10s.
wait_for() {
	local what=$1 _
	shift
	for _ in $(seq 1 100); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
	echo "timeout: $what" >&2
	return 1
}
entries() { [ -s "$TMP/state/closed.jsonl" ] && wc -l <"$TMP/state/closed.jsonl" | tr -d ' ' || echo 0; }
has_entries() { [ "$(entries)" -ge "$1" ]; }

# --- a tab with a split and a Claude pane -------------------------------------
sid=$(rex new ct-test -c "$TMP" --json | jq -r '.session_id')
out=$(rex window new -s "$sid" work -c "$TMP/a" --focus=false --json)
wid=$(jq -r '.window_id' <<<"$out")
left=$(jq -r '.block_ids[0]' <<<"$out")
right=$(rex split -s "$sid" -b "$left" --split=right --ratio 30 -c "$TMP/b" --focus=false --json -- \
	"$TMP/bin/claude" | jq -r '.block_ids[0]')
rex window new -s "$sid" last -c "$TMP" --focus=false --json >/dev/null

# Claude writes its session file. A transcript means that the session has
# messages, so the new pane resumes it.
claude_pid() { rex block call -s "$sid" -b "$right" process | jq -er 'select(.foreground.name == "claude") | .foreground.pid'; }
wait_for "fake claude starts" claude_pid
pid=$(claude_pid)
printf '{"pid":%s,"sessionId":"abc-123","cwd":"%s","name":"ct-claude"}\n' "$pid" "$TMP/b" >"$TMP/sessions/$pid.json"
slug=$(printf '%s' "$TMP/b" | tr -c 'A-Za-z0-9' '-')
mkdir -p "$TMP/projects/$slug" && : >"$TMP/projects/$slug/abc-123.jsonl"
sleep 2 # one full copy of all sessions

rex window close -s "$sid" "$wid"
wait_for "tab entry" has_entries 1
tab=$(tail -n 1 "$TMP/state/closed.jsonl")
check "a closed tab is logged as a tab" "tab ct-test work 2" \
	"$(jq -r '"\(.kind) \(.session) \(.windows[0].label) \(.windows[0].index)"' <<<"$tab")"
check "the split is kept" "horizontal 0.7" \
	"$(jq -r '.windows[0].layout.split | "\(.direction) \(.ratio)"' <<<"$tab")"
check "each pane keeps its directory" "$TMP/a $TMP/b" \
	"$(jq -r '[.windows[0].panes[].cwd] | join(" ")' <<<"$tab")"
check "the Claude pane resumes its session" "claude --resume abc-123" \
	"$(jq -r '.windows[0].layout.split.after.block.options.initial_input | rtrimstr("\n")' <<<"$tab")"
check "a shell pane starts nothing" "null" \
	"$(jq -r '.windows[0].layout.split.before.block.options.initial_input' <<<"$tab")"
id=$(jq -r '.id' <<<"$tab")
check "the picker lists the tab" "$id" "$(bash "$SCRIPT" list | cut -f1)"

# Reopen with a harmless command in place of claude.
jq -c '.windows[0].layout.split.after.block.options.initial_input = "echo RESUMED\n"' \
	"$TMP/state/closed.jsonl" >"$TMP/l" && mv "$TMP/l" "$TMP/state/closed.jsonl"
read -r rsid rwid < <(bash "$SCRIPT" reopen "$id")
check "the tab opens in its own session" "$sid" "$rsid"
view=$(rex api call -s "$sid" session.view '{}')
check "the tab is back at its position" "Window work last" \
	"$(jq -r '[.windows[].label | split(" ")[0]] | join(" ")' <<<"$view")"
check "the tab gets its split again" "0.7" \
	"$(jq -r --arg w "$rwid" '.windows[] | select(.window_id == $w) | .layers[0].layout.split.ratio' <<<"$view")"
new_right=$(jq -r --arg w "$rwid" '.windows[] | select(.window_id == $w) | .layers[0].layout.split.after.block_id' <<<"$view")
resumed() { rex capture -s "$sid" -b "$new_right" --trim | grep -q '^RESUMED'; }
wait_for "resume command runs" resumed
check "the resume command runs in the new pane" "0" "$(resumed && echo 0 || echo 1)"
check "the reopened entry leaves the log" "0" "$(entries)"

# --- a destroyed session --------------------------------------------------------
sleep 2
rex kill "$sid"
wait_for "session entry" has_entries 1
sess=$(tail -n 1 "$TMP/state/closed.jsonl")
check "a destroyed session is logged with all its tabs" "session ct-test 3" \
	"$(jq -r '"\(.kind) \(.session) \(.windows | length)"' <<<"$sess")"
read -r nsid _ < <(bash "$SCRIPT" reopen "$(jq -r '.id' <<<"$sess")")
check "the session opens again with its tabs" "ct-test 3" \
	"$(rex api call -s "$nsid" session.view '{}' | jq -r '"\(.label) \(.windows | length)"')"

exit "$fail"
