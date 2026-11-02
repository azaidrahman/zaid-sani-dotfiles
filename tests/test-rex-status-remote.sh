#!/usr/bin/env bash
# Tests for the status center of a pane on another host (usage.lua).
#
# The Rex app sends the key to the Rex of this Mac, with ctx.server set to the
# label of the host. The action must ask that host to run its own
# status_center, because only that host can find the agent of the pane and
# size the float.
#
# The call to the host goes through the app, so no test server can make it.
# Thus a Lua script loads usage.lua with stubs for rex.server and for the
# calls that open a float on this Mac. The script runs with `rex do` on a
# separate server that has an empty configuration. It never touches the live
# server. Run with bash.
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
TMP=$(mktemp -d /tmp/rexst.XXXXXX)
TMP=$(cd "$TMP" && pwd -P)
export REX_SERVER="unix://$TMP/s.sock"
SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT
unset REX_SESSION REX_BLOCK REX_CLIENT

: >"$TMP/empty.lua"
rex server run --listen "$REX_SERVER" --state-dir "$TMP/server" --restore=false \
	--config "$TMP/empty.lua" >>"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
	rex --autostart=false api call session.list '{}' >/dev/null 2>&1 && break
	sleep 0.1
done

# The script prints one line for each case: the calls that the action made,
# in order. "host" is a call to the host, "local" is a float on this Mac, and
# "error" is an error that stops the action.
cat >"$TMP/cases.lua" <<'EOF'
package.loaded.background = { start = function() end }
local actions, calls, answer = {}, {}, nil
rex.action = function(def) actions[def.name] = def end
rex.log = function() end
rex.exec = function() return nil, "stub" end
rex.block.call = function() return {} end
rex.session.view = function() return { windows = {} } end
rex.session.new_layer = function()
  calls[#calls + 1] = "local"
  return {}
end
rex.server = function(label)
  if label ~= "onyx" then error("unknown server " .. label) end
  return { call = function(method, args)
    calls[#calls + 1] = table.concat({ "host", method, args.action, args.session_id, args.block_id }, ":")
    if answer then return nil, answer end
    return {}
  end }
end
dofile(rex.args.root .. "/dot_config/rex/usage.lua")

local function case(server, err)
  calls, answer = {}, err
  local ok = pcall(actions.status_center.run, { session_id = "s1", block_id = "b1", server = server })
  if not ok then calls[#calls + 1] = "error" end
  print(table.concat(calls, " "))
end
case(nil)
case("onyx")
case("onyx", 'no action "status_center" (status=404 code=not_found)')
case("onyx", "timeout")
case("gone")
EOF

out=$(rex --autostart=false do "$TMP/cases.lua" root="$ROOT" 2>&1)
line() { sed -n "$1p" <<<"$out"; }
HOST="host:client.action:status_center:s1:b1"

check "a pane on this Mac opens the float here" "local" "$(line 1)"
check "a pane on a host asks that host" "$HOST" "$(line 2)"
check "a host without the action falls back to this Mac" "$HOST local" "$(line 3)"
check "any other error of the host stops the action" "$HOST error" "$(line 4)"
check "an unknown host falls back to this Mac" "local" "$(line 5)"

exit $fail
