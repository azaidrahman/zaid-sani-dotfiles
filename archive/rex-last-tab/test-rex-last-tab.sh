#!/usr/bin/env bash
# Tests for the tab history of Rex: last_tab.lua, last-tab-watcher.lua, and
# tab-feed.lua.
#
# The tests start a separate Rex server on a socket of their own, so they
# never touch the live server or its tab history. Run with bash.
#
# The test server has no app. Thus the test does what the app does when it
# shows a tab (show): it writes the session to the file focus.json, in place
# of the app setting Workspace.lastFocusedSession, and it makes the tab
# active on the server. Without an app, the actions only return the tab.
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
new_session() { rex new "$1" -c "$TMP" --json | jq -r '.session_id'; }
new_tab() { rex window new -s "$1" "$2" -c "$TMP" --focus=false --json | jq -r '.window_id'; }
active() { rex api call -s "$1" session.view '{}' | jq -r '.active_window_id'; }
# show SESSION WINDOW — do what the app does when it shows a tab.
show() {
	printf '{"sessionID":"%s"}' "$1" >"$TMP/focus.json"
	rex api call -s "$1" session.focus_window "{\"window_id\":\"$2\"}" >/dev/null
}
names() { sed -e "s|$s1/$a|A|g" -e "s|$s1/$b|B|g" -e "s|$s2/$c|C|g" -e "s|$s2/$d|D|g"; }
# history — the tabs, oldest first, then the current tab.
history() {
	jq -r '"\(.tabs | join(" ")) | \(.current)"' "$REX_LAST_TAB_DIR/history.json" 2>/dev/null | names
}
history_is() { [ "$(history)" = "$1" ]; }
current_is() { [ "$(history | sed 's/.*| //')" = "$1" ]; }
# press ACTION — run the action, show the tab that it returns, and print the
# current tab after the watcher sees it.
press() {
	local out sid wid
	out=$(rex do "$1" -s "$s1" --json)
	sid=$(jq -r '.session_id // empty' <<<"$out")
	wid=$(jq -r '.window_id // empty' <<<"$out")
	if [ -n "$sid" ]; then
		show "$sid" "$wid"
		wait_for "the watcher sees $1" current_is "$(names <<<"$sid/$wid")"
	fi
	history | sed 's/.*| //'
}

s1=$(new_session one)
a=$(active "$s1")
b=$(new_tab "$s1" b)
s2=$(new_session two)
c=$(active "$s2")
d=$(new_tab "$s2" d)

printf '{"sessionID":"%s"}' "$s1" >"$TMP/focus.json"
rex --autostart=false do "$WATCHER" label=test state="$REX_LAST_TAB_DIR" rex="$(command -v rex)" \
	hosts= focus="$TMP/focus.json" tick=0.1 >"$TMP/watcher.log" 2>&1 &
WATCHER_PID=$!
wait_for "the watcher reads the tab that the app shows" history_is "A | A"
show "$s1" "$b"
wait_for "the history follows a new tab" history_is "A B | B"
show "$s2" "$c"
wait_for "the history follows a new session" history_is "A B C | C"
show "$s2" "$d"
wait_for "the history follows a new tab in the new session" history_is "A B C D | D"

walk=""
for action in tab_back tab_back tab_back tab_back tab_forward tab_forward tab_forward tab_forward; do
	walk="$walk $(press $action)"
done
check "back and forward walk the history across sessions, and stop at each end" " C B A A B C D D" "$walk"
check "back and forward keep the order of the history" "A B C D | D" "$(history)"

press tab_back >/dev/null
show "$s1" "$b"
wait_for "a new tab goes last" history_is "A D C B | B"
check "after a new tab, back shows the tab that you left" "C" "$(press tab_back)"

rex window close -s "$s2" "$d" >/dev/null
wait_for "the closed tab leaves the history" history_is "A C B | C"
check "back skips a tab that closed" "A" "$(press tab_back)"

exit $fail
