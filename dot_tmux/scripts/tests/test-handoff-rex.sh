#!/usr/bin/env bash
# Tests for the Rex path of the handoff skill script
# (dot_claude/skills/handoff/handoff.sh). test-handoff-window.sh tests the tmux
# path and the checks of the input.
#
# The tests start a separate Rex server on a private socket and use a fake
# `claude` script that exits at once. They never touch the live Rex server or a
# real Claude session. Run with bash. Rex starts each pane in the login shell
# of the account, and the tests expect zsh.
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

# A Unix socket path must be shorter than 104 bytes, so keep TMP short.
TMP=$(mktemp -d -t handoff-rex)
SOCK="$TMP/s"
SRV=
cleanup() {
	[ -n "$SRV" ] && kill "$SRV" 2>/dev/null && wait "$SRV" 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

# The fake claude logs its arguments and exits. A real Claude exits when the
# user leaves it, so this is the state that the pane must survive.
mkdir -p "$TMP/bin" "$TMP/zdot" "$TMP/state" "$TMP/wt"
cat >"$TMP/bin/claude" <<EOF
#!/bin/bash
echo "\$*" >>"$TMP/calls"
EOF
chmod +x "$TMP/bin/claude"
: >"$TMP/calls"

# ZDOTDIR points the zsh of each pane at these startup files. They put the fake
# claude first in PATH, after the system files have set PATH.
printf 'export PATH=%q/bin:$PATH\nPS1="$ "\n' "$TMP" >"$TMP/zdot/.zshrc"
: >"$TMP/init.lua"
ZDOTDIR="$TMP/zdot" rex server run --listen "unix://$SOCK" --state-dir "$TMP/state" \
	--restore=false --config "$TMP/init.lua" >"$TMP/server.log" 2>&1 &
SRV=$!
for _ in $(seq 1 50); do
	[ -S "$SOCK" ] && break
	sleep 0.1
done
export REX_SERVER="unix://$SOCK"
# Stop if the CLI does not reach the private server. The checks below create
# tabs, and they must never reach the live server, which holds sessions.
if [ ! -S "$SOCK" ] || [ "$(rex ls --json --autostart=false | jq '[.sessions[]?] | length')" != 0 ]; then
	echo "FAIL - private Rex server not reached, stopping"
	cat "$TMP/server.log"
	exit 1
fi
S=$(rex new t --json | jq -er '.session_id')

run() { env -u TMUX REX_SESSION="$S" bash "$SCRIPT" "$@"; }
wait_for() { # file pattern
	local _
	for _ in $(seq 1 50); do
		grep -q -F -- "$2" "$1" 2>/dev/null && return 0
		sleep 0.1
	done
	return 1
}
calls() { wc -l <"$TMP/calls" | tr -d ' '; }
tagged() { # key → the panes with the tag of the key, as JSON
	rex block ls -s "$S" --json | jq -c --arg t "handoff:$1" '[.blocks[] | select(.label == $t)]'
}
echo brief >"$TMP/brief.md"

# --- a first run opens a tab that keeps a shell in the worktree ----------------
# The brief path holds a quote and a command substitution. rex send must type
# the command as it is.
BDIR="$TMP/it's \$(true)"
mkdir -p "$BDIR"
echo brief >"$BDIR/GTI-1.md"
out=$(run GTI-1 "$TMP/wt" "$BDIR/GTI-1.md" "GTI-1 keep")
check "first run creates the tab" "window: created GTI-1 keep" "$out"
wait_for "$TMP/calls" "$BDIR/GTI-1.md" || echo "FAIL - fake claude did not start"
check "claude gets the brief path as typed" \
	"Read $BDIR/GTI-1.md — it is your handoff brief from the session that filed GTI-1. Follow its Next step." \
	"$(tail -n 1 "$TMP/calls")"
PANE=$(tagged GTI-1 | jq -r '.[0].block_id // empty')
WIN=$(tagged GTI-1 | jq -r '.[0].window_id // empty')
check "the pane carries the key as a tag" "1" "$([ -n "$PANE" ] && echo 1 || echo 0)"
check "the tab carries the label" "GTI-1 keep" \
	"$(rex window ls -s "$S" --json | jq -r --arg w "$WIN" '.windows[] | select(.window_id == $w) | .label')"
sleep 0.3
proc=$(rex block call -s "$S" -b "$PANE" process)
check "a shell waits in the pane after claude exits" "zsh" "$(jq -r '.foreground.name' <<<"$proc")"
check "the pane is rooted in the worktree" "$(cd "$TMP/wt" && pwd -P)" "$(jq -r '.foreground.cwd' <<<"$proc")"

# --- the tab is found again by the tag, not by its label ------------------------
# The user can rename the tab. A second run must select the same tab and must
# not start claude again.
rex window rename -s "$S" "$WIN" "renamed by hand" >/dev/null
rex focus -s "$S" 1 >/dev/null
before=$(calls)
out=$(run GTI-1 "$TMP/wt" "$BDIR/GTI-1.md" "GTI-1 keep")
check "a renamed tab is reused" "window: reused GTI-1 keep" "$out"
check "the reused tab is selected" "$WIN" "$(rex session inspect "$S" --json | jq -r '.active_window_id')"
check "no second pane for the key" "1" "$(tagged GTI-1 | jq 'length')"
check "claude does not start again" "$before" "$(calls)"

# --- the key is matched as a whole key -----------------------------------------
# The tag of GTI-45 starts with the text of GTI-4. It must not be reused.
run GTI-45 "$TMP/wt" "$TMP/brief.md" "GTI-45" >/dev/null
wait_for "$TMP/calls" "filed GTI-45." || echo "FAIL - fake claude did not start"
out=$(run GTI-4 "$TMP/wt" "$TMP/brief.md" "GTI-4")
check "GTI-4 does not reuse the tab of GTI-45" "window: created GTI-4" "$out"

# --- outside tmux and Rex, the script opens nothing ----------------------------
out=$(env -u TMUX -u REX_SESSION bash "$SCRIPT" GTI-2 "$TMP/wt" "$TMP/brief.md")
check "outside tmux and Rex: exit 3 and the marker" "3 no-tmux-or-rex" "$? $out"

exit "$fail"
