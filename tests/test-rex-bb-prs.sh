#!/usr/bin/env bash
# Tests for prefix+p in Rex: bb_prs.lua.
#
# The Rex tests start a separate Rex server on a socket of their own, so they
# never touch the live server. A stub replaces bb-prs in the first test. The
# second test builds the real binary and closes the float while a refresh runs.
# Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REX_DIR="$ROOT/dot_config/rex"
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
TMP=$(mktemp -d /tmp/rexbb.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	# The refresh child runs under Setsid, so it outlives the server.
	pkill -f "$TMP/bb-prs" 2>/dev/null || true
	rm -rf "$TMP"
}
trap cleanup EXIT

# If the file "hold" exists, the stub waits, so that its pane stays open.
STUB="$TMP/stub.sh"
cat >"$STUB" <<'EOF'
#!/bin/bash
dir=$(dirname "$0")
# The test waits for stub.log, so write the session first.
echo "${REX_SESSION:-}" >>"$dir/stub.session"
echo "$PWD ${BB_PRS_POPUP:-}" >>"$dir/stub.log"
if [ -e "$dir/hold" ]; then sleep 20; fi
EOF
chmod +x "$STUB"

REPO="$TMP/repo"
mkdir -p "$REPO" "$TMP/plain"

# The real binary, with a fake twg that is slow.
mkdir -p "$TMP/fakebin" "$TMP/cache" "$TMP/state"
cat >"$TMP/fakebin/twg" <<'EOF'
#!/bin/bash
touch "$(dirname "$0")/../twg.started"
sleep 2
echo '{"currentUser":{"uuid":"{me}"},"items":[]}'
EOF
chmod +x "$TMP/fakebin/twg"
: >"$TMP/gitconfig"
(cd "$ROOT/dot_config/bb-prs/src" && go build -o "$TMP/bb-prs" .) || exit 1
cat >"$TMP/real.sh" <<EOF
#!/bin/sh
export PATH="$TMP/fakebin:\$PATH"
export XDG_CACHE_HOME="$TMP/cache" XDG_STATE_HOME="$TMP/state"
export BB_WORKSPACE=ws GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
exec "$TMP/bb-prs"
EOF
chmod +x "$TMP/real.sh"

# The float gets the environment of the server, not the environment of this
# script. Thus REX_BB_PRS is a script that runs the program in the file
# "target". Each test writes its program to that file.
cat >"$TMP/dispatch.sh" <<'EOF'
#!/bin/sh
exec "$(cat "$(dirname "$0")/target")"
EOF
chmod +x "$TMP/dispatch.sh"

# The float, on a separate Rex server.
unset REX_SESSION REX_BLOCK REX_CLIENT
export REX_SERVER="unix://$TMP/rex.sock" REX_BB_PRS="$TMP/dispatch.sh"
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("custom")\nrequire("bb_prs")\nrequire("dock")\n' \
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
list_written() { [ -s "$TMP/cache/bb-prs/list-ws-open.v3.json" ]; }
float_id() { view | jq -r '[.windows[0].layers[] | select(.kind == "floating") | .blocks[].block_id] | join(" ")'; }

# start_session NAME DIR — start a session in DIR. Set sid and opener.
start_session() {
	sid=$(rex --autostart=false new "bb-test-$1" -c "$2" --json | jq -r '.session_id')
	opener=$(view | jq -r '.windows[0].focused_block_id')
	wait_for "the shell of the opener starts" has_cwd
}

: >"$TMP/stub.log"
touch "$TMP/hold"
start_session stub "$REPO"
echo "$STUB" >"$TMP/target"
rex --autostart=false do bb_prs -s "$sid" >/dev/null
float=$(float_id)
wait_for "the float runs the stub" stub_called ||
	rex --autostart=false capture -s "$sid" -b "$float" --trim >&2
check "float: runs bb-prs in the directory of the pane" "$REPO 1" "$(cat "$TMP/stub.log")"
check "float: the program sees the session id as REX_SESSION" "$sid" "$(cat "$TMP/stub.session")"
check "float: the focused pane is the float" "$float" "$(view | jq -r '.windows[0].focused_block_id')"
rex --autostart=false kill "$sid" >/dev/null

# The float starts the refresh, then closes before the refresh ends.
start_session real "$TMP/plain"
echo "$TMP/real.sh" >"$TMP/target"
rex --autostart=false do bb_prs -s "$sid" >/dev/null
float=$(float_id)
# Close the float only after the refresh child runs, so that the check does not
# depend on how fast the program starts.
twg_started() { [ -e "$TMP/twg.started" ]; }
wait_for "the refresh child calls twg" twg_started || exit 1
rex --autostart=false block close -s "$sid" "$float" >/dev/null
float_gone() { [ -z "$(float_id)" ]; }
wait_for "the float closes" float_gone || exit 1
wait_for "the refresh writes the list" list_written
list_written && got=yes || got=no
check "refresh: lives after the float closes" "yes" "$got"

exit $fail
