#!/usr/bin/env bash
# Tests for prefix+v in Rex: scripts/special-paste.sh and special_paste.lua.
#
# Stubs replace pngpaste and ssh, so the tests never read or change the
# clipboard and never connect to a host. The pngpaste stub writes the bytes
# in IMAGE, or fails if IMAGE is empty. The ssh stub records its arguments in
# ssh.log and its stdin in upload.png, or fails if SSH_FAIL is set.
#
# A fake `ssh` in a pane stands in for a real ssh session. It is a small C
# program that writes each byte that it reads to pane.log. The Lua tests run
# the action with `rex do` on a separate Rex server, on a socket of its own,
# so they never touch the live server. Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/dot_config/rex/special_paste.lua"
export REX_SPECIAL_PASTE="$ROOT/dot_config/rex/scripts/executable_special-paste.sh"
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
TMP=$(mktemp -d /tmp/rexsp.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/pane"
cat >"$TMP/bin/pngpaste" <<'EOF'
#!/bin/bash
[ -n "${IMAGE:-}" ] || exit 1
printf '%s' "$IMAGE" >"$1"
EOF
cat >"$TMP/bin/ssh" <<EOF
#!/bin/bash
echo "\$*" >"$TMP/ssh.log"
cat >"$TMP/upload.png"
[ -z "\${SSH_FAIL:-}" ] || { echo "ssh: connect to host onyx: Connection refused" >&2; exit 255; }
EOF
cat >"$TMP/pane.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) {
	FILE *f = fopen(getenv("PANE_LOG"), "a");
	char c;
	while (f && read(0, &c, 1) == 1) { fputc(c, f); fflush(f); }
	for (;;) pause();
}
EOF
cc -o "$TMP/pane/ssh" "$TMP/pane.c" || exit 1
chmod +x "$TMP/bin/pngpaste" "$TMP/bin/ssh"
export PATH="$TMP/bin:$PATH"
export PANE_LOG="$TMP/pane.log"

# A process with the command line of an ssh session. The script reads the
# options from it with ps.
fake_ssh() {
	PANE_LOG=/dev/null "$TMP/pane/ssh" "$@" </dev/null >/dev/null 2>&1 &
	echo $!
}

# upload ARGS — run the script for an ssh process with ARGS. Print the exit
# status and the ssh call: "status=<status> ssh=<ssh args>".
upload() {
	rm -f "$TMP/ssh.log" "$TMP/upload.png"
	local pid status
	pid=$(fake_ssh "$@")
	# The Rex server has only the system directories in PATH, so `env bash`
	# finds /bin/bash, the old bash 3.2 of macOS.
	/bin/bash "$REX_SPECIAL_PASTE" "$pid" >"$TMP/out" 2>"$TMP/err"
	status=$?
	kill "$pid" 2>/dev/null
	# The remote path changes each time. Keep the part before the time.
	printf 'status=%s ssh=%s' "$status" "$(sed 's/clipboard-[0-9-]*\.png/clipboard-N.png/' "$TMP/ssh.log" 2>/dev/null)"
}

CMD="umask 077 && mkdir -p '/tmp' && cat > '/tmp/clipboard-N.png'"
SAFE="-o BatchMode=yes -o ConnectTimeout=10"

# The script. Columns: label | image | ssh args | expected.
while IFS='|' read -r label image args want; do
	# shellcheck disable=SC2086 # args is a list of words
	check "script: $label" "$want" "$(IMAGE=$image upload $args)"
done <<EOF
no image: no upload, status 3|||status=3 ssh=
plain host|PNG|onyx|status=0 ssh=$SAFE onyx $CMD
keep -p -A -J -i, drop -L -t -N|PNG|-p2222 -L 8080:h:80 -tA -N -J jump -i key user@onyx -v|status=0 ssh=-p 2222 -A -J jump -i key $SAFE user@onyx $CMD
EOF

IMAGE=PNG upload onyx >/dev/null
check "script: ssh gets the image on stdin" "PNG" "$(cat "$TMP/upload.png")"

SSH_FAIL=1 IMAGE=PNG upload onyx >/dev/null
check "script: a failed upload tells why" \
	"the upload to onyx failed: ssh: connect to host onyx: Connection refused" "$(cat "$TMP/err")"

# The Lua action ----------------------------------------------------------

unset REX_SESSION REX_BLOCK REX_CLIENT
export REX_SERVER="unix://$TMP/rex.sock"
: >"$TMP/init.lua"
r() { rex --autostart=false "$@"; }

rex server run --listen "$REX_SERVER" --state-dir "$TMP/server" --restore=false \
	--config "$TMP/init.lua" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do r api call session.list '{}' >/dev/null 2>&1 && break; sleep 0.1; done

# The live server always has sessions. If this server has one, the tests
# talk to the wrong server, so stop before they change anything.
if [ "$(r api call session.list '{}' | jq '.sessions | length')" != 0 ]; then
	echo "abort: the test server is not empty" >&2
	exit 1
fi

# There is no app, so no client can do pane.paste. The wrapper records each
# client action in queue.log in place of the app.
cat >"$TMP/wrapper.lua" <<EOF
rex.client.queue = function(action)
  local f = io.open("$TMP/queue.log", "a")
  f:write(action, "\n")
  f:close()
end
dofile("$MODULE")
EOF

sid=$(r new sp-test --json | jq -r '.session_id')
# The fake ssh reads each byte at once: stty turns off the line buffer.
ssh_pane=$(r window new -s "$sid" ssh --shell none --json -- /bin/sh -c \
	'stty -icanon -echo; exec "$0" -p 2222 onyx' "$TMP/pane/ssh" | jq -r '.block_ids[0]')
cat_pane=$(r window new -s "$sid" cat --shell none --json -- /bin/cat | jq -r '.block_ids[0]')

# foreground BLOCK — the name of the foreground program of BLOCK.
foreground() { r block call -s "$sid" -b "$1" process 2>/dev/null | jq -r '.foreground.name // empty'; }
for _ in $(seq 1 50); do [ "$(foreground "$ssh_pane")" = ssh ] && break; sleep 0.1; done
check "lua: the fake ssh is the foreground program" "ssh" "$(foreground "$ssh_pane")"

# paste BLOCK — run the action on BLOCK. Print what the pane got and what the
# action queued: "pane=<input> queue=<actions>".
paste() {
	: >"$PANE_LOG"
	: >"$TMP/queue.log"
	r do -s "$sid" -b "$1" "$TMP/wrapper.lua" --action special_paste >"$TMP/do.log" 2>&1 || sed "s/^/      do: /" "$TMP/do.log" >&2
	sleep 0.3
	printf 'pane=%s queue=%s' \
		"$(sed 's/clipboard-[0-9-]*\.png/clipboard-N.png/' "$PANE_LOG")" \
		"$(tr '\n' ' ' <"$TMP/queue.log" | sed 's/ $//')"
}

# The action. Columns: label | image | pane | expected.
while IFS='|' read -r label image pane want; do
	check "lua: $label" "$want" "$(IMAGE=$image paste "$pane")"
done <<EOF
ssh and an image: paste the remote path|PNG|$ssh_pane|pane=/tmp/clipboard-N.png queue=
ssh and no image: normal paste||$ssh_pane|pane= queue=pane.paste
not ssh: normal paste, no upload|PNG|$cat_pane|pane= queue=pane.paste
EOF

# --- A pane on a Rex host --------------------------------------------------
# The app sends the key with ctx.server set to the label of the host. The call
# to the host goes through the app, so no test server can make it. Thus a
# script loads the module with a stub for rex.server. Each case prints, in
# order: the host of the upload ("ssh:<host>"), each call to the host
# ("host:<method>:<block>:<text>"), each client action ("queue:<action>"),
# and "error" if the action stops.
cat >"$TMP/remote.lua" <<EOF
local actions, calls = {}, {}
rex.action = function(def) actions[def.name] = def end
rex.client.queue = function(action) calls[#calls + 1] = "queue:" .. action end
rex.server = function(label)
  if label ~= "ONYX" then error("unknown server " .. label) end
  return { call = function(method, req)
    if method == "session.view" then
      return { active_window_id = "w1", windows = { { window_id = "w1", focused_block_id = "b9" } } }
    end
    local text = (req.event.payload.text or ""):gsub("clipboard%-[%d-]+%.png", "clipboard-N.png")
    calls[#calls + 1] = table.concat({ "host", method, req.block_id, text }, ":")
    return {}
  end }
end
dofile("$MODULE")

local function case(server, block_id)
  calls = {}
  os.remove("$TMP/ssh.log")
  local ok = pcall(actions.special_paste.run, { session_id = "s1", block_id = block_id, server = server })
  local f = io.open("$TMP/ssh.log")
  if f then table.insert(calls, 1, "ssh:" .. f:read("*l"):match("(%S+) umask")) f:close() end
  if not ok then calls[#calls + 1] = "error" end
  print(table.concat(calls, " "))
end
case("ONYX", "b1")
case("ONYX", nil)
case("gone", "b1")
EOF

# remote IMAGE — run the cases with IMAGE on the clipboard stub.
remote() { IMAGE=$1 r do "$TMP/remote.lua" 2>&1; }
out=$(remote PNG)
line() { sed -n "$1p" <<<"$out"; }
check "host: upload with ssh onyx, then the host pastes the path" \
	"ssh:onyx host:block.event:b1:/tmp/clipboard-N.png" "$(line 1)"
check "host: no block in ctx: paste into the focused pane of the host" \
	"ssh:onyx host:block.event:b9:/tmp/clipboard-N.png" "$(line 2)"
check "host: an unknown host stops the action before the upload" "error" "$(line 3)"
check "host: no image: normal paste, no upload" "queue:pane.paste" "$(remote "" | sed -n 1p)"

exit "$fail"
