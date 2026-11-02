#!/usr/bin/env bash
# Tests for held sessions and the tab picker of Rex: hold.lua,
# hold-watcher.lua, tab-picker.lua and tab-picker.sh.
#
# The tests start a separate Rex server on a socket of their own, so they
# never touch the live server, its hold list or its cache. A fake `claude`
# stands in for Claude. It is a small C program, because macOS stops a copy
# of a system program such as sleep. Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REX_DIR="$ROOT/dot_config/rex"
WATCHER="$REX_DIR/scripts/hold-watcher.lua"
PICKER="$REX_DIR/scripts/executable_tab-picker.sh"
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
TMP=$(mktemp -d /tmp/rexhold.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
SERVER_PID="" WATCHER_PID=""
cleanup() {
	[ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

unset REX_SESSION REX_BLOCK REX_CLIENT REX_TABS_CLIENT
export REX_SERVER="unix://$TMP/rex.sock"
export REX_HOLD_DIR="$TMP/hold" XDG_CACHE_HOME="$TMP/cache"
export CLAUDE_SESSIONS_DIR="$TMP/sessions" CLAUDE_PROJECTS_DIR="$TMP/projects"
mkdir -p "$TMP/bin" "$TMP/hold" "$TMP/cache" "$TMP/sessions" "$TMP/projects" "$TMP/a"
printf '#include <unistd.h>\nint main(void) { for (;;) pause(); }\n' >"$TMP/claude.c"
cc -o "$TMP/bin/claude" "$TMP/claude.c" || exit 1
# An agent that waits for you: it reports `blocked` (OSC 7501), then runs.
printf '#!/bin/sh\nprintf "\\033]7501;state=blocked:app=test\\033\\\\"\nexec "%s/bin/claude"\n' "$TMP" >"$TMP/bin/agent"
chmod +x "$TMP/bin/agent"
# The configuration loads hold.lua from this checkout.
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("hold")\n' "$REX_DIR" >"$TMP/init.lua"

rex server run --listen "$REX_SERVER" --state-dir "$TMP/server" --restore=false \
	--config "$TMP/init.lua" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do rex --autostart=false api call session.list '{}' >/dev/null 2>&1 && break; sleep 0.1; done

# wait_for DESCRIPTION COMMAND... — run COMMAND until it succeeds, for 10s.
wait_for() {
	local what=$1 _
	shift
	for _ in $(seq 1 100); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
	echo "timeout: $what" >&2
	return 1
}
labels() { rex api call session.list '{}' | jq -r '[.sessions[].label] | join(",")'; }
held() { [ -f "$REX_HOLD_DIR/held" ] && paste -sd, - <"$REX_HOLD_DIR/held" || true; }
toggle() { rex do toggle_hold -s "$1" >/dev/null; }
new_session() { rex new --json "$@" | jq -r '.session_id'; }
first_key() { rex window ls -s "$1" --json | jq -r '.windows[0].window_id[-8:]'; }
# rows MODE — the rows of the picker without colors.
rows() { bash "$PICKER" list "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
# column N MODE — one column of the rows, joined with commas.
column() { rows "$2" | awk -F'│' -v n="$1" '{ c = $n; sub(/^ *(● *)?/, "", c); sub(/ *$/, "", c); print c }' | paste -sd, -; }

# --- hold and release -----------------------------------------------------------
a=$(new_session alpha -c "$TMP")
b=$(new_session bravo -c "$TMP")
c=$(new_session charlie -c "$TMP")

toggle "$a"
check "hold marks the session and moves it to the end" "bravo,charlie,[HOLD] alpha|$a" "$(labels)|$(held)"

toggle "$b"
toggle "$a"
check "release removes the marker and puts the session above the held ones" \
	"charlie,alpha,[HOLD] bravo|$b" "$(labels)|$(held)"

# --- the watcher ----------------------------------------------------------------
echo "session:gone" >>"$REX_HOLD_DIR/held"
rex --autostart=false do --all "$WATCHER" label=test state="$REX_HOLD_DIR" >"$TMP/watcher.log" 2>&1 &
WATCHER_PID=$!
wait_for "the watcher drops a session that is gone" sh -c "[ \"\$(paste -sd, - <'$REX_HOLD_DIR/held')\" = '$b' ]"
check "the watcher drops a session that is gone" "$b" "$(held)"

rex session rename "$b" renamed >/dev/null
wait_for "the marker comes back" sh -c "rex api call session.list '{}' | grep -q '\\[HOLD\\] renamed'"
check "a rename of a held session keeps the marker" "charlie,alpha,[HOLD] renamed" "$(labels)"

rex kill "$b" >/dev/null
wait_for "the list forgets the session" sh -c "[ ! -s '$REX_HOLD_DIR/held' ]"
check "a destroyed session leaves the list" "" "$(held)"

# --- the tab picker ---------------------------------------------------------------
rex kill "$a" "$c" >/dev/null
w=$(new_session work -c "$TMP")
agent=$(rex window new -s "$w" agent -c "$TMP/a" --focus=false --json -- "$TMP/bin/agent" | jq -r '.block_ids[0]')
p=$(new_session parked -c "$TMP")
toggle "$p"
q=$(new_session quickterminal -c "$TMP" -- sh -c "echo preview-marker; exec '$TMP/bin/claude'")

# The agent writes its session file and a transcript with one answer.
claude_pid() { rex block call -s "$w" -b "$agent" process | jq -er 'select(.foreground.name == "claude") | .foreground.pid'; }
wait_for "fake claude starts" claude_pid
pid=$(claude_pid)
printf '{"pid":%s,"sessionId":"sess-1","cwd":"%s"}\n' "$pid" "$TMP/a" >"$TMP/sessions/$pid.json"
slug=$(printf '%s' "$TMP/a" | tr -c 'A-Za-z0-9' '-')
mkdir -p "$TMP/projects/$slug"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"last words"}]}}\n' \
	>"$TMP/projects/$slug/sess-1.jsonl"
wait_for "the agent reports its state" sh -c "rex block call -s '$w' -b '$agent' program_status | grep -q blocked"

check "each group lists the tabs of its sessions" \
	"work,work|[HOLD] parked|quickterminal" \
	"$(column 1 active)|$(column 1 hold)|$(column 1 other)"
check "a tab that waits comes first, with its last output" \
	"last words" "$(rows active | head -n 1 | awk -F'│' '{ sub(/^ */, "", $4); sub(/ *$/, "", $4); print $4 }')"
check "the preview shows the screen of the tab" \
	"preview-marker" "$(bash "$PICKER" preview "$(first_key "$q")" | grep -o 'preview-marker' | head -n 1)"

exit $fail
