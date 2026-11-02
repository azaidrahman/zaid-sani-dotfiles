#!/usr/bin/env bash
# Tests for the last tab of Rex: last_tab.lua and last-tab-watcher.lua.
#
# The tests start a separate Rex server on a socket of their own, so they
# never touch the live server or its tab history. Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REX_DIR="$ROOT/dot_config/rex"
WATCHER="$REX_DIR/scripts/last-tab-watcher.lua"
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
TMP=$(mktemp -d /tmp/rexlt.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
SERVER_PID="" WATCHER_PID=""
cleanup() {
	[ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

unset REX_SESSION REX_BLOCK REX_CLIENT
export REX_SERVER="unix://$TMP/rex.sock"
export REX_LAST_TAB_DIR="$TMP/state"
# The configuration loads last_tab.lua from this checkout.
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("last_tab")\n' "$REX_DIR" >"$TMP/init.lua"

rex server run --listen "$REX_SERVER" --state-dir "$TMP/server" --restore=false \
	--config "$TMP/init.lua" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do rex --autostart=false api call session.list '{}' >/dev/null 2>&1 && break; sleep 0.1; done
if [ "$(rex api call session.list '{}' | jq '.sessions | length')" != 0 ]; then
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
new_tab() { rex window new -s "$sid" "$1" -c "$TMP" --focus=false --json | jq -r '.window_id'; }
active() { rex api call -s "$sid" session.view '{}' | jq -r '.active_window_id'; }
focus() { rex api call -s "$sid" session.focus_window "{\"window_id\":\"$1\"}" >/dev/null; }
# history — the tabs of the session in the history, newest first, as names.
history() {
	jq -r --arg s "$sid" '.sessions[$s] // [] | join(" ")' "$REX_LAST_TAB_DIR/history.json" 2>/dev/null |
		sed -e "s/$a/A/g" -e "s/$b/B/g" -e "s/$c/C/g"
}
history_is() { [ "$(history)" = "$1" ]; }
last_tab() { rex do last_tab -s "$sid" >/dev/null; }

sid=$(rex new lt-test -c "$TMP" --json | jq -r '.session_id')
a=$(active)
b=$(new_tab b)
c=$(new_tab c)

# The watcher starts after the tabs exist, so it reads the active tab.
rex --autostart=false do --all "$WATCHER" label=test state="$REX_LAST_TAB_DIR" >"$TMP/watcher.log" 2>&1 &
WATCHER_PID=$!
wait_for "the watcher reads the active tab" history_is "A"
focus "$b"
focus "$c"
wait_for "the history follows the focus" history_is "C B A"

last_tab
first=$(active)
wait_for "the history records the last tab" history_is "B C A"
last_tab
check "the action goes back to the last tab, then forward again" "$b $c" "$first $(active)"

rex window close -s "$sid" "$b" >/dev/null
wait_for "the closed tab leaves the history" history_is "C A"
last_tab
check "the action skips a tab that closed" "$a" "$(active)"

exit $fail
