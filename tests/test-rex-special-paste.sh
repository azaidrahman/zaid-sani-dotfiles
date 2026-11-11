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
	bash "$REX_SPECIAL_PASTE" "$pid" >"$TMP/out" 2>"$TMP/err"
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

exit "$fail"
