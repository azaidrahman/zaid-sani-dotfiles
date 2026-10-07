#!/usr/bin/env bash
# Tests for closed-windows.sh (prefix+X) and status-jobs.sh.
#
# The tests use a separate tmux server (tmux -L) and a fake `claude` script,
# so they never touch the live server or a real Claude session. Run with bash.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/executable_closed-windows.sh"
JOBS="$DIR/executable_status-jobs.sh"
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

# --- cw_resume_cmd ------------------------------------------------------------
TMP=$(mktemp -d)
touch "$TMP/abcde.jsonl"
check "claude pane resumes its session" "claude --resume abcde" \
	"$(cw_resume_cmd 2.1.0 "$TMP/abcde.jsonl")"
check "a transcript that is not on disk starts fresh" "claude" \
	"$(cw_resume_cmd claude "$TMP/none.jsonl")"
check "a shell pane with an old transcript starts nothing" "" \
	"$(cw_resume_cmd zsh "$TMP/abcde.jsonl")"
check "a login shell starts nothing" "" "$(cw_resume_cmd -zsh "$TMP/abcde.jsonl")"
check "a pane without a transcript starts nothing" "" "$(cw_resume_cmd nvim '')"

# --- end to end on a separate tmux server -------------------------------------
SOCK="cw-test-$$"
cleanup() {
	tmux -L "$SOCK" kill-server 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/a" "$TMP/b"
cat >"$TMP/bin/claude" <<EOF
#!/bin/bash
echo "\$*" >>"$TMP/calls"
EOF
chmod +x "$TMP/bin/claude"

# Each pane runs a plain bash with the fake claude first in PATH.
SHELL_CMD="env -i HOME=$HOME PATH=$TMP/bin:/usr/bin:/bin bash --norc --noprofile"
cat >"$TMP/tmux.conf" <<EOF
set -g default-command "$SHELL_CMD"
set -g status-right "THEME"
set-environment -g TMUX_CLOSED_DIR "$TMP/state"
set-hook -g window-unlinked 'run-shell -b "bash $SCRIPT record #{hook_window} #{q:hook_session_name} #{q:hook_window_name}"'
EOF
T() { tmux -L "$SOCK" "$@"; }
T -f "$TMP/tmux.conf" new-session -d -s main -n keep -x 160 -y 40
SOCK_PATH=$(T display-message -p '#{socket_path}')
case "$SOCK_PATH" in *"$SOCK"*) ;; *)
	echo "FAIL - test socket not found, stopping"
	exit 1
	;;
esac
# The script calls plain `tmux`. $TMUX points it at the test server.
run() { TMUX="$SOCK_PATH,0,0" TMUX_CLOSED_DIR="$TMP/state" bash "$SCRIPT" "$@"; }
wait_for() { # file pattern
	local _
	for _ in $(seq 1 50); do
		grep -q -- "$2" "$1" 2>/dev/null && return 0
		sleep 0.1
	done
	return 1
}
entries() { [ -f "$TMP/state/closed.jsonl" ] && wc -l <"$TMP/state/closed.jsonl" | tr -d ' ' || echo 0; }

# status-jobs.sh adds both jobs once, after the theme text.
TMUX="$SOCK_PATH,0,0" HOME="$TMP" bash "$JOBS"
TMUX="$SOCK_PATH,0,0" HOME="$TMP" bash "$JOBS"
check "status-jobs adds the snapshot job once" \
	"THEME#($TMP/.tmux/scripts/closed-windows.sh snapshot)" "$(T show -gv status-right)"
mkdir -p "$TMP/.tmux/plugins/tmux-continuum/scripts"
touch "$TMP/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh"
chmod +x "$TMP/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh"
T set -g status-right "THEME"
TMUX="$SOCK_PATH,0,0" HOME="$TMP" bash "$JOBS"
check "status-jobs adds the continuum job again" "1" \
	"$(T show -gv status-right | grep -c 'continuum_save.sh)')"

# A window with two panes: a shell in a/, and a Claude pane in b/.
W=$(T new-window -d -t main -n work -c "$TMP/a" -P -F '#{window_id}')
P2=$(T split-window -d -t "$W" -c "$TMP/b" -P -F '#{pane_id}')
T select-pane -t "$P2" -T "my claude topic"
T set-option -p -t "$P2" @claude_transcript "$TMP/abcde.jsonl"
# A process that is not a shell, so the pane counts as a running Claude.
T send-keys -t "$P2" "sleep 300" Enter
sleep 0.5

run snapshot
check "snapshot lists the panes of the window" "2" \
	"$(awk -F'\t' -v w="$W" '$2 == w' "$TMP/state/panes.tsv" | wc -l | tr -d ' ')"

# Kill the window. The hook logs it.
T kill-window -t "$W"
wait_for "$TMP/state/closed.jsonl" '"name":"work"' || true
check "a killed window is logged" "1" "$(entries)"
check "the entry keeps both directories" "$TMP/a|$TMP/b" \
	"$(jq -r '[.panes[].cwd] | join("|")' "$TMP/state/closed.jsonl" | sed "s|/private$TMP|$TMP|g")"
check "the entry keeps the Claude topic" "my claude topic" \
	"$(jq -r '.panes[1].title' "$TMP/state/closed.jsonl")"

ID=$(jq -r '.id' "$TMP/state/closed.jsonl")
list=$(run list)
case "$list" in "$ID"$'\t'*work*"(my claude topic)"*) r=ok ;; *) r="$list" ;; esac
check "list shows the window and its topic" "ok" "$r"
check "preview shows the Claude session id" "1" "$(run preview "$ID" | grep -c 'session  abcde')"

# A window that moves to another session is not closed.
T new-session -d -s other
W2=$(T new-window -d -t main -n mover -P -F '#{window_id}')
run snapshot
T move-window -s "$W2" -t other:
sleep 0.5
check "a moved window is not logged" "1" "$(entries)"

# A window that closes before any snapshot saw it is not logged.
W3=$(T new-window -d -t main -n flash -P -F '#{window_id}')
T kill-window -t "$W3"
sleep 0.5
check "a window with no snapshot is not logged" "1" "$(entries)"

# A window of a zen session is not logged.
T new-session -d -s zen -n zenwin
T set -t zen @zen_owned 1
run snapshot
T kill-session -t zen
sleep 0.5
check "a zen window is not logged" "1" "$(entries)"

# Reopen: same session, name, panes, directories; Claude resumes.
run reopen "$ID"
NW=$(T list-windows -t main -F '#{window_name} #{window_id}' | awk '$1 == "work" {print $2}')
check "reopen makes the window in the same session" "1" "$([ -n "$NW" ] && echo 1)"
check "reopen makes both panes" "$TMP/a|$TMP/b" \
	"$(T list-panes -t "$NW" -F '#{pane_current_path}' | paste -sd'|' - | sed "s|/private$TMP|$TMP|g")"
wait_for "$TMP/calls" "resume" || true
check "reopen resumes the Claude session" "--resume abcde" "$(cat "$TMP/calls" 2>/dev/null)"
check "reopen removes the entry" "0" "$(entries)"

# Reopen when the session closed with its last window: make the session again.
T new-session -d -s gone -n lone -c "$TMP/a"
run snapshot
T kill-session -t gone
wait_for "$TMP/state/closed.jsonl" '"name":"lone"' || true
run reopen "$(jq -r 'select(.name == "lone") | .id' "$TMP/state/closed.jsonl")"
check "reopen makes a closed session again" "lone" "$(T list-windows -t gone -F '#{window_name}' 2>/dev/null)"

exit "$fail"
