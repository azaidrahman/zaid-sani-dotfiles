#!/usr/bin/env bash
# Tests for restart-claude-pane.sh (prefix+A).
#
# The unit tests cover the pure functions. The end-to-end tests use a separate
# tmux server (tmux -L) and a fake `claude` script, so they never touch the
# live server or a real Claude session. Run with bash.
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/executable_restart-claude-pane.sh"
fail=0
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   - %s\n' "$1"
	else
		printf 'FAIL - %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

out=$(
	source "$SCRIPT" 2>/dev/null
	echo "SOURCED_OK"
)
check "source is side-effect free" "SOURCED_OK" "$out"
source "$SCRIPT"

# --- rc_find_claude -----------------------------------------------------------
check "native claude under a shell" "300" "$(printf '%s\n' \
	'100 1 -zsh' '200 100 /bin/zsh' '300 200 claude --model opus' '400 300 caffeinate -i' |
	rc_find_claude)"
check "npm claude runs under node" "300" "$(printf '%s\n' \
	'100 1 -zsh' '300 100 node /opt/homebrew/bin/claude' | rc_find_claude)"
check "outermost claude wins" "300" "$(printf '%s\n' \
	'100 1 -zsh' '300 100 claude' '310 300 claude mcp serve' | rc_find_claude)"
check "claude-resurrect is not claude" "" "$(printf '%s\n' \
	'100 1 -zsh' '300 100 /bin/bash /x/claude-resurrect' | rc_find_claude)"
check "no claude" "" "$(printf '%s\n' '100 1 -zsh' '200 100 nvim' | rc_find_claude)"

# --- rc_launch_cmd ------------------------------------------------------------
check "plain resume" "claude --resume abc" "$(rc_launch_cmd abc 0)"
check "fresh start without a transcript" "claude" "$(rc_launch_cmd '' 0)"
check "permission flags carry over" \
	"claude --allow-dangerously-skip-permissions --resume abc" \
	"$(rc_launch_cmd abc 0 --allow-dangerously-skip-permissions)"
check "cv drops the flag that cv adds" "cv --resume abc" \
	"$(rc_launch_cmd abc 1 --allow-dangerously-skip-permissions)"
check "model and permission mode carry over" \
	"claude --model opus --permission-mode=plan --resume abc" \
	"$(rc_launch_cmd abc 0 --model opus --permission-mode=plan)"
check "old resume, continue and prompt are dropped" "claude --resume abc" \
	"$(rc_launch_cmd abc 0 --resume old -c --fork-session 'fix it')"

# --- end to end on a separate tmux server -------------------------------------
SOCK="rc-test-$$"
TMP=$(mktemp -d)
cleanup() {
	tmux -L "$SOCK" kill-server 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin"
cat >"$TMP/bin/claude" <<EOF
#!/bin/bash
echo "\$*" >>"$TMP/calls"
trap 'echo TERM >>"$TMP/calls"; exit 0' TERM
while :; do sleep 0.1; done
EOF
chmod +x "$TMP/bin/claude"
touch "$TMP/abcde-session.jsonl"

# The fake claude must win over the real one. respawn-pane takes PATH from the
# tmux client that sends it, so run() puts the fake first in PATH too.
echo 'set -g default-shell /bin/bash' >"$TMP/tmux.conf"
T() { PATH="$TMP/bin:$PATH" tmux -L "$SOCK" "$@"; }
T -f "$TMP/tmux.conf" new-session -d -s t -x 120 -y 30 "env -i HOME=$HOME PATH=$TMP/bin:/usr/bin:/bin bash --norc --noprofile"
SOCK_PATH=$(T display-message -p '#{socket_path}')
case "$SOCK_PATH" in *"$SOCK"*) ;; *)
	echo "FAIL - test socket not found, stopping"
	exit 1
	;;
esac
# The script calls plain `tmux`. $TMUX points it at the test server.
run() { PATH="$TMP/bin:$PATH" TMUX="$SOCK_PATH,0,0" TMUX_PANE='' bash "$SCRIPT" "$@"; }
pane_tty() { T display-message -p -t "$1" '#{pane_tty}'; }
wait_for() { # file pattern
	local _
	for _ in $(seq 1 50); do
		grep -q -- "$2" "$1" 2>/dev/null && return 0
		sleep 0.1
	done
	return 1
}

# Claude under a shell: stop it, then type the resume command into the shell.
P=$(T display-message -p -t t '#{pane_id}')
T set-option -p -t "$P" @claude_transcript "$TMP/abcde-session.jsonl"
T send-keys -t "$P" "claude --model opus 'a prompt'" Enter
wait_for "$TMP/calls" "a prompt" || echo "FAIL - fake claude did not start"
run "$P" "$(pane_tty "$P")" ''
wait_for "$TMP/calls" "resume" || true
check "claude under a shell is resumed" \
	"--model opus a prompt|TERM|--model opus --resume abcde-session" \
	"$(paste -sd'|' "$TMP/calls")"

# Claude as the first process of the pane: respawn the pane. respawn-pane -k
# stops it with SIGHUP, so the fake does not log TERM here.
: >"$TMP/calls"
P2=$(T new-window -d -P -F '#{pane_id}' "env PATH=$TMP/bin:/usr/bin:/bin claude --permission-mode plan")
T set-option -p -t "$P2" @claude_transcript "$TMP/abcde-session.jsonl"
wait_for "$TMP/calls" "plan" || echo "FAIL - fake claude did not start"
run "$P2" "$(pane_tty "$P2")" ''
wait_for "$TMP/calls" "resume" || true
check "claude as the pane process is respawned" \
	"--permission-mode plan|--permission-mode plan --resume abcde-session" \
	"$(paste -sd'|' "$TMP/calls")"

# A pane with no claude: no restart, and no kill.
P3=$(T new-window -d -P -F '#{pane_id}' "bash --norc --noprofile")
run "$P3" "$(pane_tty "$P3")" ''
check "non-claude pane exits 0" "0" "$?"
check "non-claude pane is still alive" "1" "$(T list-panes -t "$P3" -F x 2>/dev/null | wc -l | tr -d ' ')"

# Claude with no tag on the pane: no restart.
: >"$TMP/calls"
P4=$(T new-window -d -P -F '#{pane_id}' "env PATH=$TMP/bin:/usr/bin:/bin bash --norc --noprofile")
T send-keys -t "$P4" "claude untagged" Enter
wait_for "$TMP/calls" "untagged" || echo "FAIL - fake claude did not start"
run "$P4" "$(pane_tty "$P4")" ''
sleep 0.3
check "untagged claude is not stopped" "untagged" "$(paste -sd'|' "$TMP/calls")"

exit "$fail"
