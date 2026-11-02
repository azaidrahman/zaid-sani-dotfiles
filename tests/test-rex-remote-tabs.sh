#!/usr/bin/env bash
# Tests for the copy of the tabs on other hosts: remote-tabs-watcher.lua,
# host-tabs-watcher.lua, tabs.lua, and list-tabs.lua.
#
# The tests start two separate Rex servers on sockets of their own, with an
# empty configuration. One server is this Mac, and the other server is a
# host. The tests never touch the live server or its copies. Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/dot_config/rex/scripts"
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
TMP=$(mktemp -d /tmp/rexrt.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
LOCAL="unix://$TMP/l.sock"
HOST="unix://$TMP/h.sock"
LOCAL_PID="" HOST_PID=""
cleanup() {
	# The watchers are detached. Their arguments hold the path of TMP.
	pkill -f "out=$TMP/" 2>/dev/null
	pkill -f "state=$TMP/" 2>/dev/null
	[ -n "$HOST_PID" ] && kill "$HOST_PID" 2>/dev/null
	[ -n "$LOCAL_PID" ] && kill "$LOCAL_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

unset REX_SESSION REX_BLOCK REX_CLIENT
export REX_SERVER="$LOCAL"
# background.lua finds the rex binary in the command line of the server, so
# the server must start from a full path.
REX=$(command -v rex)
: >"$TMP/empty.lua"

# The server of this Mac starts the watcher as init.lua does, through
# background.lua. The heartbeat is long, so only an event can update the copy
# in the test.
cat >"$TMP/init.lua" <<EOF
package.path = "$ROOT/dot_config/rex/?.lua;" .. package.path
require("background").start({
  "$DIR/remote-tabs-watcher.lua", "label=test", "state=$TMP/state",
  "hosts=$HOST", "check=0.2", "retry=1", "heartbeat=60",
})
EOF

# start_server SOCKET CONFIG — start a server, and wait until it answers. The
# PID goes to SERVER_PID. A server that the Rex app starts has no rex in its
# PATH, so the test server has none either.
start_server() {
	env PATH=/usr/bin:/bin:/usr/sbin:/sbin \
		"$REX" server run --listen "$1" --state-dir "$TMP/srv-${1##*/}" --restore=false \
		--config "$2" >>"$TMP/server.log" 2>&1 &
	SERVER_PID=$!
	for _ in $(seq 1 50); do
		rex --autostart=false -S "$1" api call session.list '{}' >/dev/null 2>&1 && return 0
		sleep 0.1
	done
	echo "timeout: server $1 starts" >&2
	return 1
}

# wait_for DESCRIPTION COMMAND... — run COMMAND until it succeeds, for 10s.
wait_for() {
	local what=$1 _
	shift
	for _ in $(seq 1 100); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
	echo "timeout: $what" >&2
	return 1
}

start_server "$HOST" "$TMP/empty.lua" || exit 1
HOST_PID=$SERVER_PID

sid=$(rex --autostart=false -S "$HOST" new rt-test -c "$TMP" --window alpha --json | jq -r '.session_id')
wid=$(rex --autostart=false -S "$HOST" window ls -s "$sid" --json | jq -r '.windows[0].window_id')

# --- list-tabs.lua -------------------------------------------------------------
labels=$(rex --autostart=false -S "$HOST" do "$DIR/list-tabs.lua" --json | jq -r '[.tabs[].wlabel] | join(",")')
check "list-tabs.lua lists the tabs of a server" "alpha" "$labels"

# --- the copy of the host -------------------------------------------------------
start_server "$LOCAL" "$TMP/init.lua" || exit 1
LOCAL_PID=$SERVER_PID
COPY="$TMP/state/$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9.-' '_').json"

copy_has() { jq -e "$1" "$COPY"; }
wait_for "the copy lists alpha" copy_has '.tabs[0].wlabel == "alpha"'
check "the copy lists the tabs of the host" "alpha|$HOST|true" \
	"$(jq -r '[.tabs[0].wlabel, .server, (.host_id != "")] | map(tostring) | join("|")' "$COPY")"

rex --autostart=false -S "$HOST" window rename -s "$sid" "$wid" beta
wait_for "the copy lists beta" copy_has '.tabs[0].wlabel == "beta"'
check "the copy follows a change on the host" "beta" "$(jq -r '.tabs[0].wlabel' "$COPY")"

# --- a host that stops, and comes back -------------------------------------------
kill "$HOST_PID"
wait "$HOST_PID" 2>/dev/null
wait_for "the copy holds an error" copy_has '.error'
check "the copy holds an error when the host stops" "true|0" \
	"$(jq -r '[(.error | length > 0), (.tabs | length)] | map(tostring) | join("|")' "$COPY")"

start_server "$HOST" "$TMP/empty.lua" || exit 1
HOST_PID=$SERVER_PID
wait_for "the copy has no error" copy_has '.error == null'
check "the watcher starts again when the host comes back" "null" "$(jq -r '.error' "$COPY")"

if [ "$fail" -ne 0 ]; then
	echo "--- server log"
	cat "$TMP/server.log"
fi
exit "$fail"
