#!/usr/bin/env bash
# Tests for the handoff skill script (dot_claude/skills/handoff/handoff.sh).
#
# The tests use a separate tmux server (tmux -L) and a fake `claude` script
# that exits at once, so they never touch the live server or a real Claude
# session. Run with bash.
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../dot_claude/skills/handoff" && pwd)/executable_handoff.sh"
fail=0
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   - %s\n' "$1"
	else
		printf 'FAIL - %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

SOCK="ho-test-$$"
TMP=$(mktemp -d)
cleanup() {
	tmux -L "$SOCK" kill-server 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

# The fake claude logs its arguments and exits. A real Claude exits when the
# user leaves it, so this is the state that the window must survive.
mkdir -p "$TMP/bin" "$TMP/wt"
cat >"$TMP/bin/claude" <<EOF
#!/bin/bash
echo "\$*" >>"$TMP/calls"
EOF
chmod +x "$TMP/bin/claude"

# Each pane runs a plain bash with the fake claude first in PATH. The server
# gets the same PATH, for a window command that the server starts itself.
# The prompt holds an em dash. Without a UTF-8 locale, readline reads its
# bytes as meta keys and changes the typed line.
SHELL_CMD="env -i HOME=$HOME LC_ALL=en_US.UTF-8 PATH=$TMP/bin:/usr/bin:/bin bash --norc --noprofile"
printf '%s\n' 'set -g default-shell /bin/bash' "set -g default-command \"$SHELL_CMD\"" >"$TMP/tmux.conf"
T() { tmux -L "$SOCK" "$@"; }
PATH="$TMP/bin:$PATH" T -f "$TMP/tmux.conf" new-session -d -s t -n keep -x 160 -y 40
SOCK_PATH=$(T display-message -p '#{socket_path}')
case "$SOCK_PATH" in *"$SOCK"*) ;; *)
	echo "FAIL - test socket not found, stopping"
	exit 1
	;;
esac
# The script calls plain `tmux`. $TMUX points it at the test server.
run() { TMUX="$SOCK_PATH,0,0" TMUX_PANE='' bash "$SCRIPT" "$@"; }
wait_for() { # file pattern
	local _
	for _ in $(seq 1 50); do
		grep -q -F -- "$2" "$1" 2>/dev/null && return 0
		sleep 0.1
	done
	return 1
}
window_by_name() { T list-windows -t t -F '#{window_id}|#{window_name}' | awk -F'|' -v n="$1" '$2 == n {print $1; exit}'; }
calls() { wc -l <"$TMP/calls" 2>/dev/null | tr -d ' '; }

# --- the window survives the exit of claude -----------------------------------
# The brief path holds a quote and a command substitution. The typed command
# must pass it as one word, and must not run it.
BDIR="$TMP/it's \$(touch $TMP/pwned)"
mkdir -p "$BDIR"
echo brief >"$BDIR/GTI-1.md"
out=$(run GTI-1 "$TMP/wt" "$BDIR/GTI-1.md" "GTI-1 keep")
check "first run creates the window" "window: created GTI-1 keep" "$out"
wait_for "$TMP/calls" "$BDIR/GTI-1.md" || echo "FAIL - fake claude did not start"
sleep 0.3
WIN=$(window_by_name "GTI-1 keep")
check "window is still open after claude exits" "1" "$([ -n "$WIN" ] && echo 1 || echo 0)"
check "a shell waits in the pane" "bash" "$(T display-message -p -t "$WIN" '#{pane_current_command}' 2>/dev/null)"
# tmux reports the physical path, so compare with pwd -P.
check "pane is rooted in the worktree" "$(cd "$TMP/wt" && pwd -P)" "$(T display-message -p -t "$WIN" '#{pane_current_path}' 2>/dev/null)"
check "a quote in the brief path does not run a command" "0" "$([ -e "$TMP/pwned" ] && echo 1 || echo 0)"
check "claude gets the brief path as typed" \
	"Read $BDIR/GTI-1.md — it is your handoff brief from the session that filed GTI-1. Follow its Next step." \
	"$(tail -n 1 "$TMP/calls" 2>/dev/null)"

# --- a second run for the same key reuses the window --------------------------
out=$(run GTI-1 "$TMP/wt" "$BDIR/GTI-1.md" "GTI-1 keep")
check "second run reuses the window" "window: reused GTI-1 keep" "$out"
check "no second window for the key" "1" "$(T list-windows -t t -F '#{window_name}' | grep -c '^GTI-1 keep$')"
check "claude is not started again" "1" "$(calls)"

# --- the key is matched as plain text, and as a whole key ---------------------
# A window of another key can hold the text of this key. It must not be reused.
echo brief >"$TMP/brief.md"
T new-window -d -t t: -n "GTI-45 other"
before=$(calls)
out=$(run GTI-4 "$TMP/wt" "$TMP/brief.md" "GTI-4 prefix")
check "GTI-4 does not reuse the window of GTI-45" "window: created GTI-4 prefix" "$out"
wait_for "$TMP/calls" "filed GTI-4." || echo "FAIL - fake claude did not start"
check "claude starts for GTI-4" "$((before + 1))" "$(calls)"

# A character of a regular expression in the key is only a character.
T new-window -d -t t: -n "GTI-9 other"
out=$(run 'GT.-9' "$TMP/wt" "$TMP/brief.md" "GT.-9 regex")
check "a dot in the key does not match any character" "window: created GT.-9 regex" "$out"

# A window that carries only the key is the window of that key.
T new-window -d -t t: -n "GTI-7"
before=$(calls)
out=$(run GTI-7 "$TMP/wt" "$TMP/brief.md" "GTI-7 bare")
check "a window named only with the key is reused" "window: reused GTI-7 bare" "$out"
check "claude does not start for a reused bare window" "$before" "$(calls)"

exit "$fail"
