#!/usr/bin/env bash
# Tests for zen mode in Rex: dot_config/rex/zen.lua.
#
# The tests start a separate Rex server on a socket of their own, so they
# never touch the live server or its zen state. The tests run the action with
# `rex do`, as the CLI. The CLI has no sidebar and no text size, so the tests
# check only the layout. Run with bash.
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
TMP=$(mktemp -d /tmp/rexzen.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

unset REX_SESSION REX_BLOCK REX_CLIENT
export REX_SERVER="unix://$TMP/rex.sock"
export REX_ZEN_DIR="$TMP/zen"
# The configuration loads zen.lua from this checkout.
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("zen")\n' "$REX_DIR" >"$TMP/init.lua"

rex server run --listen "$REX_SERVER" --state-dir "$TMP/server" --restore=false \
	--config "$TMP/init.lua" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do rex --autostart=false api call session.list '{}' >/dev/null 2>&1 && break; sleep 0.1; done

# The live server always has sessions. If this server has one, the tests
# talk to the wrong server, so stop.
if [ "$(rex --autostart=false api call session.list '{}' | jq '.sessions | length')" != 0 ]; then
	echo "FAIL - the test server is not empty; stop before the tests touch it"
	exit 1
fi

view() { rex api call session.view "$(jq -nc --arg s "$s" '{session_id: $s}')"; }
# tiled — the tiled layout of the main tab, with the IDs and the sizes.
tiled() { view | jq -c --arg w "$main" '.windows[] | select(.window_id == $w) | .layers[] | select(.kind == "tiled") | .layout'; }
labels() { view | jq -r '[.windows[].label] | join(",")'; }
focused() { view | jq -r '. as $v | .windows[] | select(.window_id == $v.active_window_id) | .focused_block_id'; }
# floats — the floats of the main tab, back to front, as label:bounds.
floats() {
	view | jq -r --arg w "$main" '[.windows[] | select(.window_id == $w) | .layers[]
		| select(.kind != "tiled")
		| "\(.blocks[0].label):\(.bounds | map(. * 1000 | round / 1000) | join("/"))"] | join(",")'
}
zen() { rex do zen -s "$s" -b "$1" --json; }
state() { jq -c 'length' "$REX_ZEN_DIR/zen.json"; }

# A tab with three panes: a on the left, b above c on the right. The neighbour
# of b is one pane, but the neighbour of the right column is a split. tmux
# could not put a pane back into a place like that without extra steps.
created=$(rex new work -c "$TMP" --window main --json)
s=$(printf '%s' "$created" | jq -r '.session_id')
a=$(printf '%s' "$created" | jq -r '.initial_windows[0].block_ids[0]')
main=$(printf '%s' "$created" | jq -r '.initial_windows[0].window_id')
b=$(rex split -s "$s" -b "$a" --split=right --json | jq -r '.block_ids[0]')
c=$(rex split -s "$s" -b "$b" --split=below --json | jq -r '.block_ids[0]')
rex window new -s "$s" last -c "$TMP" --focus=false --json >/dev/null
before=$(tiled)

# --- enter ----------------------------------------------------------------------
placeholder=$(zen "$b" | jq -r '.placeholder_id')
check "enter floats the pane in the middle of its own tab, in front of a backdrop" \
	"main,last|zen backdrop:0/0/1/1,shell:0.125/0/0.75/1|$b" "$(labels)|$(floats)|$(focused)"
check "enter puts the placeholder in the place of the pane" \
	"${before//$b/$placeholder}" "$(tiled)"

# --- leave ----------------------------------------------------------------------
# cmd+w runs close_or_leave_zen. In zen mode, it must not close the pane.
rex do close_or_leave_zen -s "$s" -b "$b" >/dev/null
check "cmd+w in zen mode puts the layout back and closes the placeholder and the backdrop" \
	"$before||$b|0" "$(tiled)|$(floats)|$(focused)|$(state)"

# --- a lost placeholder ---------------------------------------------------------
placeholder=$(zen "$b" | jq -r '.placeholder_id')
rex block close -s "$s" "$placeholder" >/dev/null
restored=$(zen "$b" | jq -r '.restored')
# a and c are the same size, so a is the largest pane: it comes first.
beside=$(tiled | jq -r --arg b "$b" '.. | objects | select(.split.after.block_id? == $b) | .split.before.block_id')
check "leave without the placeholder docks the pane beside the largest pane of its tab" \
	"beside|$a|" "$restored|$beside|$(floats)"

# --- a pane that closed ---------------------------------------------------------
# When the pane in zen mode closes, focus goes to the backdrop. zen in the
# backdrop closes the placeholder and the backdrop, and does nothing more.
zen "$c" >/dev/null
backdrop=$(jq -r '.[0].backdrop_id' "$REX_ZEN_DIR/zen.json")
rex block close -s "$s" "$c" >/dev/null
check "zen after the pane closed removes the placeholder and the backdrop" \
	"true|$a,$b|" "$(zen "$backdrop" | jq -r '.cleaned')|$(tiled | jq -r '[.. | objects | .block_id? // empty] | join(",")')|$(floats)"

exit $fail
