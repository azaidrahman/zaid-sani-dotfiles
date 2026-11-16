#!/usr/bin/env bash
# Tests for the nvim setup of Rex copy mode: scripts/copy-mode-nvim.lua.
#
# Each run has its own HOME and XDG_DATA_HOME in a temp folder, so the tests
# never read the real nvim data. The copy tests run nvim in a pseudo-terminal
# with the script command. Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$ROOT/dot_config/rex/scripts/copy-mode-nvim.lua"
NVIM="${NVIM:-nvim}"
fail=0
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   - %s\n' "$1"
	else
		printf 'FAIL - %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

# Keep the real data folder, to find flash.nvim for the jump test.
TMP_REAL_HOME=$HOME
XDG_DATA_HOME_REAL=${XDG_DATA_HOME:-}
TMP=$(mktemp -d /tmp/rexcm.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/data"
export HOME="$TMP/home" XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/home/.config"

headless() { # lua expression
	printf x | "$NVIM" --headless -R -n -u "$SETUP" - -c "lua io.write($1)" -c 'qa!' 2>&1
}

check "buffer is read-only" "false" "$(headless 'tostring(vim.bo.modifiable)')"
check "no state files" "false||false" \
	"$(headless 'tostring(vim.o.undofile)..[[|]]..vim.o.shada..[[|]]..tostring(vim.o.swapfile)')"

# Run nvim in a pseudo-terminal. Send the keys after a delay. Stop after 10 s.
# A | in the keys is a pause of 1 s, as when a person waits for the labels.
# Sets RUN_OUT (the terminal output) and RUN_EXIT (0 if nvim quit in time).
# The second argument is the value of REX_COPY_JUMP. Use "jump" for jump mode.
run_pty() { # keys [jump]
	local out="$TMP/pty.out" pid feeder i
	: >"$out"
	exec 3< <(sleep 1; printf '%s' "${1%%|*}"; case $1 in *'|'*) sleep 1; printf '%s' "${1#*|}" ;; esac; sleep 12)
	feeder=$!
	# The text comes on stdin, as in production. The keys come from the tty.
	# The text has two lines. The argument + must put the cursor on the last.
	REX_COPY_JUMP=${2:-} script -q "$out" sh -c 'printf "apple\nhello\n" | "$0" -R -n --noplugin -u "$1" + -' "$NVIM" "$SETUP" <&3 >/dev/null 2>&1 &
	pid=$!
	exec 3<&-
	RUN_EXIT=1
	for i in $(seq 1 100); do
		if ! kill -0 "$pid" 2>/dev/null; then
			RUN_EXIT=0
			break
		fi
		sleep 0.1
	done
	kill "$pid" 2>/dev/null
	# Stop the feeder and its sleep, so that they do not outlive the run.
	pkill -P "$feeder" 2>/dev/null
	kill "$feeder" 2>/dev/null
	wait "$pid" 2>/dev/null
	RUN_OUT=$(cat -v "$out")
}

# Use the C locale. Flash draws a non-ASCII icon, and grep in a UTF-8 locale
# then can miss a match on the same line.
count() { printf '%s' "$RUN_OUT" | LC_ALL=C grep -c "$1"; }

run_pty 'vey'
check "visual y copies with OSC 52 and quits" "0:1" "$RUN_EXIT:$(count '52;c;aGVsbG8=')"
# Nvim writes nvim.log for its own errors. It holds no pane text. Ignore it.
check "copy run writes no file in the test home or data folder" "" "$(find "$TMP/home" "$TMP/data" -type f ! -name nvim.log)"

run_pty 'q'
check "q quits without copying" "0:0" "$RUN_EXIT:$(count '52;c;')"

# Jump mode starts on the last line. Type "app" to get to the first line.
# The test data folder has no flash.nvim, so jump mode starts a / search.
run_pty $'app\rvey' jump
check "jump without flash: a / search goes to the word" "0:1" "$RUN_EXIT:$(count '52;c;YXBwbGU=')"

# Use the flash.nvim of this Mac, if it is on disk. Flash shows the label a
# on the only match. The test skips if flash is missing.
FLASH="${XDG_DATA_HOME_REAL:-$TMP_REAL_HOME/.local/share}/nvim/lazy/flash.nvim"
if [ -d "$FLASH" ]; then
	mkdir -p "$TMP/data/nvim/lazy"
	ln -s "$FLASH" "$TMP/data/nvim/lazy/flash.nvim"
	run_pty 'app|avey' jump
	check "jump with flash: the label goes to the word" "0:1" "$RUN_EXIT:$(count '52;c;YXBwbGU=')"
	rm "$TMP/data/nvim/lazy/flash.nvim"
else
	printf 'skip - jump with flash: flash.nvim is not at %s\n' "$FLASH"
fi

# Float program: scripts/executable_copy-mode.sh. Stub rex and nvim come first
# in PATH. The stub rex prints capture.txt, or fails if rex.fail exists. The
# stub nvim saves its arguments and its stdin.
SCRIPT="$ROOT/dot_config/rex/scripts/executable_copy-mode.sh"
# The script finds the setup file next to itself, so use a copy in a folder
# that has the deployed names.
mkdir -p "$TMP/deploy" "$TMP/stubs" "$TMP/stubs-nonvim" "$TMP/out" "$TMP/tmpdir"
cp "$SCRIPT" "$TMP/deploy/copy-mode.sh"
cp "$SETUP" "$TMP/deploy/copy-mode-nvim.lua"
cat >"$TMP/stubs/rex" <<STUB
#!$BASH
printf '%s\n' "\$@" >"$TMP/out/rex.args"
[ -e "$TMP/out/rex.fail" ] && exit 1
exec /bin/cat "$TMP/out/capture.txt"
STUB
cat >"$TMP/stubs/nvim" <<STUB
#!$BASH
printf '%s\n' "\$@" >"$TMP/out/nvim.args"
printf '%s' "\${REX_COPY_JUMP-unset}" >"$TMP/out/nvim.jump"
/bin/cat >"$TMP/out/nvim.stdin"
STUB
cp "$TMP/stubs/rex" "$TMP/stubs-nonvim/rex"
chmod +x "$TMP/stubs/rex" "$TMP/stubs/nvim" "$TMP/stubs-nonvim/rex"

# Sets FLOAT_OUT and FLOAT_EXIT. The newline on stdin answers the Enter wait.
run_float() { # path [jump]
	rm -f "$TMP/out/nvim.args" "$TMP/out/nvim.stdin"
	FLOAT_OUT=$(printf '\n' | env PATH="$1:/usr/bin:/bin" TMPDIR="$TMP/tmpdir" \
		/bin/sh "$TMP/deploy/copy-mode.sh" '$1' '%2' ${2:+"$2"} 2>&1)
	FLOAT_EXIT=$?
}

printf 'h\303\251llo \346\227\245\346\234\254\nsecond line\n' >"$TMP/out/capture.txt"
run_float "$TMP/stubs"
check "float: text reaches nvim unchanged" "$(cat "$TMP/out/capture.txt")" "$(cat "$TMP/out/nvim.stdin")"
check "float: nvim gets the read-only flags and the setup file" "-R -n --noplugin -u $TMP/deploy/copy-mode-nvim.lua + -" \
	"$(tr '\n' ' ' <"$TMP/out/nvim.args" | sed 's/ $//')"
check "float: capture call has session, pane, --trim and --unwrap in order" 'capture -s $1 -b %2 --trim --unwrap' \
	"$(tr '\n' ' ' <"$TMP/out/rex.args" | sed 's/ $//')"
check "float: no files written" "" "$(ls -A "$TMP/tmpdir")"

run_float "$TMP/stubs" jump
check "float: jump argument reaches nvim as REX_COPY_JUMP" "jump" "$(cat "$TMP/out/nvim.jump")"

: >"$TMP/out/capture.txt"
run_float "$TMP/stubs"
check "float: empty pane starts nvim" "yes" "$([ -e "$TMP/out/nvim.args" ] && echo yes || echo no)"

touch "$TMP/out/rex.fail"
run_float "$TMP/stubs"
check "float: capture error" "1:yes:no" \
	"$FLOAT_EXIT:$(case $FLOAT_OUT in *'copy mode:'*) echo yes ;; *) echo no ;; esac):$([ -e "$TMP/out/nvim.args" ] && echo yes || echo no)"
rm -f "$TMP/out/rex.fail"

run_float "$TMP/stubs-nonvim"
check "float: nvim missing" "1:yes" \
	"$FLOAT_EXIT:$(case $FLOAT_OUT in *'copy mode:'*) echo yes ;; *) echo no ;; esac)"

# The action, on a separate Rex server. The socket is in $TMP, so the path is
# short, and the live server is never used. A stub script records its
# arguments, then waits, so that the float stays open.
REX_DIR="$ROOT/dot_config/rex"
unset REX_SESSION REX_BLOCK REX_CLIENT
export REX_SERVER="unix://$TMP/rex.sock"
cat >"$TMP/gate.sh" <<EOF
#!/bin/bash
echo "\$*" >"$TMP/gate.log"
sleep 20
EOF
chmod +x "$TMP/gate.sh"
export REX_COPY_MODE="$TMP/gate.sh"
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("copy_mode")\n' \
	"$REX_DIR" >"$TMP/init.lua"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"' EXIT
rex server run --listen "$REX_SERVER" --state-dir "$TMP/server" --restore=false \
	--config "$TMP/init.lua" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do rex --autostart=false api call session.list '{}' >/dev/null 2>&1 && break; sleep 0.1; done
if [ "$(rex --autostart=false api call session.list '{}' | jq '.sessions | length')" != 0 ]; then
	echo "the test server has sessions, so it can be the live server" >&2
	exit 1
fi

wait_for() { # description command...
	local what=$1 _
	shift
	for _ in $(seq 1 100); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
	echo "timeout: $what" >&2
	return 1
}
view() { rex --autostart=false api call -s "$sid" session.view '{}'; }
gate_called() { [ -s "$TMP/gate.log" ]; }

sid=$(rex --autostart=false new cm-test -c "$TMP" --json | jq -r '.session_id')
opener=$(view | jq -r '.windows[0].focused_block_id')

rex --autostart=false do copy_mode -s "$sid" >/dev/null 2>&1
float=$(view | jq -r '[.windows[0].layers[] | select(.kind == "floating") | .blocks[].block_id] | join(" ")')
wait_for "the float runs the script" gate_called
check "action: the float runs the script with the session and the pane" \
	"$sid $opener" "$(cat "$TMP/gate.log")"
check "action: the float has focus" "$float" "$(view | jq -r '.windows[0].focused_block_id')"

# copy_jump opens a second float over the first one. It must target the pane
# below the floats, so give it the pane in the context.
rm -f "$TMP/gate.log"
rex --autostart=false do copy_jump -s "$sid" -b "$opener" >/dev/null 2>&1
wait_for "the jump float runs the script" gate_called
check "action: copy_jump adds the jump argument" "$sid $opener jump" "$(cat "$TMP/gate.log")"

# A session with no window has no focused pane.
rm -f "$TMP/gate.log"
empty=$(rex --autostart=false api call session.create '{"label":"cm-empty"}' | jq -r '.session_id')
out=$(rex --autostart=false do copy_mode -s "$empty" 2>&1)
status=$?
check "action: no focused pane is an error with no float" "fail:yes:no" \
	"$([ "$status" != 0 ] && echo fail || echo ok):$(case $out in *'no pane has focus'*) echo yes ;; *) echo no ;; esac):$([ -e "$TMP/gate.log" ] && echo yes || echo no)"

exit $fail
