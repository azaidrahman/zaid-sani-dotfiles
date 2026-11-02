#!/usr/bin/env bash
# Tests for ctrl+h/j/k/l between nvim and the panes around it:
# dot_config/nvim/lua/zaid/core/navigator.lua and dot_config/rex/navigator.lua.
#
# nvim uses a copy of the nvim configuration of this checkout and the plugins
# that are installed. A plugin that replaces the mappings makes the tests
# fail. The tests start a separate tmux server and a separate Rex server, so
# they never touch the live servers. Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
TMP=$(mktemp -d /tmp/nav.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
TMUX_SOCKET="$TMP/tmux.sock"
SERVER_PID=""
cleanup() {
	tmux -S "$TMUX_SOCKET" kill-server 2>/dev/null
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

# The copy keeps lazy.nvim from writing a lock file into the checkout.
mkdir -p "$TMP/config"
cp -R "$ROOT/dot_config/nvim" "$TMP/config/nvim"
cp "$HOME/.config/nvim/lazy-lock.json" "$TMP/config/nvim/" 2>/dev/null

# nvim_cmd SOCKET prints the command that starts nvim with this
# configuration. The socket lets the tests ask nvim for its state.
nvim_cmd() { printf 'env XDG_CONFIG_HOME=%q nvim --listen %q' "$TMP/config" "$1"; }
nvim_expr() { nvim --server "$1" --remote-expr "$2" 2>/dev/null; }
nvim_wait() { # socket: wait until nvim has started
	local _
	for _ in $(seq 1 200); do
		[ "$(nvim_expr "$1" 'v:vim_did_enter')" = 1 ] && return 0
		sleep 0.05
	done
	return 1
}
until_eq() { # expected command...: print the output when it is expected, or after 3 s
	local want=$1 out _
	shift
	for _ in $(seq 1 60); do
		out=$("$@" 2>/dev/null)
		[ "$out" = "$want" ] && break
		sleep 0.05
	done
	printf '%s' "$out"
}

unset TMUX TMUX_PANE REX_SESSION REX_BLOCK REX_CLIENT
export REX_SERVER="unix://$TMP/rex.sock"

# --- Rex ----------------------------------------------------------------------
# The configuration defines the actions with navigator.lua from this checkout.
# The keys are bound to these actions, and the app runs the action of a key.
# The CLI cannot press a key in the app, so the tests run the actions with
# `rex do`. tests/test-rex-keys.sh checks the keys of init.lua.
cat >"$TMP/init.lua" <<EOF
package.path = "$ROOT/dot_config/rex/?.lua;" .. package.path
require("navigator")
EOF

rex server run --listen "$REX_SERVER" --state-dir "$TMP/rex" --restore=false \
	--config "$TMP/init.lua" >"$TMP/rex.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
	[ -S "$TMP/rex.sock" ] && break
	sleep 0.1
done
# Stop if the CLI does not reach the private server. The checks below change
# the focus, and they must never reach the live server.
if [ "$(rex ls --json --autostart=false | jq '[.sessions[]?] | length')" != 0 ]; then
	echo "FAIL - private Rex server not reached, stopping"
	cat "$TMP/rex.log"
	exit 1
fi

S=$(rex new t --json | jq -er '.session_id')
LEFT=$(rex block ls -s "$S" --json | jq -er '.blocks[0].block_id')
RIGHT=$(rex split -s "$S" -b "$LEFT" --split right --focus=false --json | jq -er '.block_ids[0]')
rex_focused() { rex session inspect "$S" --json | jq -r '.windows[0].focused_block_id'; }

# Do not use exec. After exec, Rex sees login as the foreground program, and
# the binding focuses the pane itself, not nvim.
rex send -s "$S" -b "$LEFT" "$(nvim_cmd "$TMP/rex-nvim.sock")"
rex send-key -s "$S" -b "$LEFT" enter
nvim_wait "$TMP/rex-nvim.sock" || echo "FAIL - nvim in Rex did not start"
check "rex: the action sees nvim as the foreground program" nvim \
	"$(rex block call -s "$S" -b "$LEFT" process | jq -r '.foreground.name')"
rex focus -s "$S" "$LEFT" >/dev/null

# The action sends ctrl+l to nvim itself.
nvim_expr "$TMP/rex-nvim.sock" 'execute("vsplit | wincmd h")' >/dev/null
rex do -s "$S" -b "$LEFT" navigate_right >/dev/null
check "rex: ctrl+l in an nvim split goes to the nvim window on the right" \
	2 "$(until_eq 2 nvim_expr "$TMP/rex-nvim.sock" 'winnr()')"
check "rex: ctrl+l in an nvim split does not leave nvim" "$LEFT" "$(rex_focused)"

rex do -s "$S" -b "$LEFT" navigate_right >/dev/null
check "rex: ctrl+l at the right edge of nvim focuses the pane on the right" \
	"$RIGHT" "$(until_eq "$RIGHT" rex_focused)"

# --- tmux ---------------------------------------------------------------------
# REX_SESSION is set, as in tmux in a Rex pane. The tmux pane must win.
T() { tmux -S "$TMUX_SOCKET" -f /dev/null "$@"; }
T new-session -d -s t -x 160 -y 40 \
	"env REX_SESSION=$S $(nvim_cmd "$TMP/tmux-nvim.sock")"
T split-window -h -d -t t:0.0 'sleep 600'
nvim_wait "$TMP/tmux-nvim.sock" || echo "FAIL - nvim in tmux did not start"
tmux_pane() { T display-message -p -t t '#{pane_index}'; }

T send-keys -t t:0.0 C-l
check "tmux: ctrl+l at the right edge of nvim focuses the pane on the right" \
	1 "$(until_eq 1 tmux_pane)"

T select-pane -t t:0.0
T send-keys -t t:0.0 'C-\'
check "tmux: ctrl+\\ after a move to a pane goes back to that pane" \
	1 "$(until_eq 1 tmux_pane)"

T select-pane -t t:0.0
nvim_expr "$TMP/tmux-nvim.sock" 'execute("vsplit | wincmd h")' >/dev/null
T send-keys -t t:0.0 C-l
check "tmux: ctrl+l in an nvim split goes to the nvim window on the right" \
	2 "$(until_eq 2 nvim_expr "$TMP/tmux-nvim.sock" 'winnr()')"
check "tmux: ctrl+l in an nvim split does not leave nvim" 0 "$(tmux_pane)"

exit "$fail"
