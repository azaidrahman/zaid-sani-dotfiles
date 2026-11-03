#!/usr/bin/env bash
# Tests for the restart_claude action of Rex (dot_config/rex/restart_claude.lua).
#
# The tests start a separate Rex server on a socket of their own, with an
# empty configuration, so they never touch the live server. A fake `claude`
# stands in for Claude. It is a small C program that writes its pid and its
# arguments to a log, then waits. The shells of the panes read the .zshrc in
# ZDOTDIR. That file puts the fake claude first in PATH and defines cv, so a
# typed command never starts the real Claude. Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/dot_config/rex/restart_claude.lua"
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
TMP=$(mktemp -d /tmp/rexrc.XXXXXX)
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
export CLAUDE_CONFIG_DIR="$TMP/claude"
export FAKE_LOG="$TMP/claude.log"
export ZDOTDIR="$TMP/zdot"
WORK="$TMP/work"
mkdir -p "$TMP/bin" "$ZDOTDIR" "$CLAUDE_CONFIG_DIR/sessions" "$WORK"
cat >"$TMP/claude.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
	FILE *f = fopen(getenv("FAKE_LOG"), "a");
	if (f) {
		fprintf(f, "%d", (int)getpid());
		for (int i = 1; i < argc; i++) fprintf(f, " %s", argv[i]);
		fputc('\n', f);
		fclose(f);
	}
	for (;;) pause();
}
EOF
cc -o "$TMP/bin/claude" "$TMP/claude.c" || exit 1
cat >"$ZDOTDIR/.zshrc" <<EOF
PATH="$TMP/bin:\$PATH"
PS1='READY> '
cv() { claude "\$@"; }
EOF
: >"$FAKE_LOG"
: >"$TMP/init.lua"

r() { rex --autostart=false "$@"; }

# The panes get the environment of the server. Put the fake claude first in
# PATH there too, so that no pane can start the real Claude.
PATH="$TMP/bin:$PATH" rex server run --listen "$REX_SERVER" --state-dir "$TMP/server" --restore=false \
	--config "$TMP/init.lua" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do r api call session.list '{}' >/dev/null 2>&1 && break; sleep 0.1; done

# The live server always has sessions. If this server has one, the tests
# talk to the wrong server, so stop before they change anything.
if [ "$(r api call session.list '{}' | jq '.sessions | length')" != 0 ]; then
	echo "abort: the test server is not empty" >&2
	exit 1
fi

# wait_for DESCRIPTION COMMAND... — run COMMAND until it succeeds, for 10s.
# A timeout is a failure of the tests.
wait_for() {
	local what=$1 _
	shift
	for _ in $(seq 1 100); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
	printf 'FAIL - timeout: %s\n' "$what"
	fail=1
	return 1
}
fg_pid() { r block call -s "$sid" -b "$1" process | jq -r '.foreground.pid'; }
ready() { r capture -s "$sid" -b "$1" --trim | grep -q 'READY>'; }
log_lines() { wc -l <"$FAKE_LOG" | tr -d ' '; }
has_lines() { [ "$(log_lines)" -ge "$1" ]; }
# session_file PID ID — write the file that Claude keeps for a process.
session_file() {
	printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$1" "$2" "$WORK" \
		>"$CLAUDE_CONFIG_DIR/sessions/$1.json"
}
restart() { rex --autostart=false do -s "$sid" "$MODULE" --action restart_claude block_id="$1" --json; }

sid=$(r new rc-test -c "$WORK" --json | jq -r '.session_id')

# --- Claude in a shell: stop it, and type the resume command -------------------
# The old process came from cv, so the new command uses cv. Only the known
# flags carry over: -p and its prompt do not.
shell=$(r window new -s "$sid" shell -c "$WORK" --json | jq -r '.block_ids[0]')
wait_for "prompt of the shell" ready "$shell"
r send -s "$sid" -b "$shell" \
	'ANTHROPIC_BASE_URL=http://proxy claude --model opus -p hello --dangerously-skip-permissions'
r send-key -s "$sid" -b "$shell" enter
wait_for "claude in the shell" has_lines 1
old=$(fg_pid "$shell")
session_file "$old" S1
project=$(printf '%s' "$WORK" | sed 's/[^[:alnum:]]/-/g')
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$project"
: >"$CLAUDE_CONFIG_DIR/projects/$project/S1.jsonl"

out=$(restart "$shell")
check "shell: the command resumes with cv and the known flags" \
	"cv --model opus --dangerously-skip-permissions --resume S1" "$(jq -r '.command' <<<"$out")"
check "shell: the old claude stopped" "no" "$(kill -0 "$old" 2>/dev/null && echo yes || echo no)"
wait_for "new claude in the shell" has_lines 2
check "shell: the shell started the new claude" \
	"--model opus --dangerously-skip-permissions --resume S1" "$(tail -n 1 "$FAKE_LOG" | cut -d' ' -f2-)"

# --- Claude as the program of the pane: a shell takes the space of the pane ----
# The session has no transcript, so the new command starts a fresh session.
created=$(r window new -s "$sid" direct -c "$WORK" --json -- "$TMP/bin/claude")
wid=$(jq -r '.window_id' <<<"$created")
direct=$(jq -r '.block_ids[0]' <<<"$created")
wait_for "claude as the program of the pane" has_lines 3
old=$(fg_pid "$direct")
session_file "$old" S2

out=$(restart "$direct")
new=$(jq -r '.block_id' <<<"$out")
check "direct: the command starts a new session" "claude" "$(jq -r '.command' <<<"$out")"
check "direct: the action typed into a new pane" "yes" "$([ "$new" != "$direct" ] && echo yes || echo no)"
# blocks lists the blocks of the tab of the direct test.
blocks() {
	r block ls -s "$sid" --json |
		jq -r --arg w "$wid" '[.blocks[] | select(.window_id == $w) | .block_id] | sort | join(" ")'
}
only_new() { [ "$(blocks)" = "$new" ]; }
wait_for "old pane closes" only_new
check "direct: the new shell is the only pane of the tab" "$new" "$(blocks)"
wait_for "new claude in the shell" has_lines 4
check "direct: the new shell started claude with no flags" "" "$(tail -n 1 "$FAKE_LOG" | cut -s -d' ' -f2-)"

# --- No Claude in the pane: the action fails and types nothing -----------------
idle=$(r window new -s "$sid" idle -c "$WORK" --json | jq -r '.block_ids[0]')
wait_for "prompt of the idle shell" ready "$idle"
check "no claude: the action fails" "no" "$(restart "$idle" >/dev/null 2>&1 && echo yes || echo no)"

# --- A pane on another host: the host restarts Claude --------------------------
# The app sends the key with ctx.server set to the label of the host. The call
# to the host goes through the app, so no test server can make it. Thus a
# script loads the module with a stub for rex.server. Each case prints the
# calls that the action made, in order: "host" is a call to the host, "local"
# is a look at a process on this Mac, and "error" stops the action. The action
# must never look on this Mac, because the pid belongs to the host.
cat >"$TMP/remote.lua" <<'EOF'
local actions, calls, answer = {}, {}, nil
rex.action = function(def) actions[def.name] = def end
rex.block.call = function() calls[#calls + 1] = "local" end
rex.exec = function() calls[#calls + 1] = "local" end
rex.server = function(label)
  if label ~= "onyx" then error("unknown server " .. label) end
  return { call = function(method, req)
    local arg = req.args and req.args.block_id or "-"
    calls[#calls + 1] = table.concat({ "host", method, req.action, req.session_id, req.block_id, arg }, ":")
    if answer then return nil, answer end
    return {}
  end }
end
dofile(rex.args.module)

local function case(server, args, err)
  calls, answer = {}, err
  local ok = pcall(actions.restart_claude.run, { session_id = "s1", block_id = "b1", server = server }, args)
  if not ok then calls[#calls + 1] = "error" end
  print(table.concat(calls, " "))
end
case("onyx", {})
case("onyx", { block_id = "b2" })
case("onyx", {}, 'no action "restart_claude" (status=404 code=not_found)')
case("gone", {})
EOF
out=$(r do "$TMP/remote.lua" module="$MODULE" 2>&1)
line() { sed -n "$1p" <<<"$out"; }
HOST="host:client.action:restart_claude:s1"
check "remote: the host restarts the focused pane" "$HOST:b1:-" "$(line 1)"
check "remote: the host gets the block_id argument" "$HOST:b2:b2" "$(line 2)"
check "remote: a host without the action stops the action" "$HOST:b1:- error" "$(line 3)"
check "remote: an unknown host stops the action" "error" "$(line 4)"

exit "$fail"
