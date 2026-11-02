#!/usr/bin/env bash
# Tests for the keys of the Rex configuration: dot_config/rex/init.lua and
# custom.lua.
#
# The Command Palette must show each key of init.lua in the Custom
# group, and the palette search must find the action by its key. The test
# loads init.lua with `rex config check`. That command loads the file in the
# CLI, so it starts no server and no watcher (background.lua). Run with bash.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

TMP=$(mktemp -d /tmp/rexkeys.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# The test configuration loads init.lua from this checkout. Then it writes
# the bindings to a file, because `rex config check` reports only how many
# bindings there are.
cat >"$TMP/check.lua" <<EOF
package.path = "$ROOT/dot_config/rex/?.lua;" .. package.path
require("init")
local out = {}
for _, b in ipairs(rex.bindings()) do
  out[#out + 1] = { key = b.key, action = b.action or "(a function)", source = b.source }
end
rex.exec({ "/bin/sh", "-c", 'printf "%s" "\$1" >"\$2"', "sh",
  rex.json.encode(out), "$TMP/bindings.json" })
EOF

if ! rex config check "$TMP/check.lua" --json >"$TMP/check.json"; then
	echo "FAIL - rex config check reports an error"
	jq -r '.diagnostics[] | "      \(.)"' "$TMP/check.json"
	exit 1
fi
if [ "$(jq '.diagnostics | length' "$TMP/check.json")" != 0 ]; then
	echo "FAIL - rex config check reports a warning"
	jq -r '.diagnostics[] | "      \(.)"' "$TMP/check.json"
	fail=1
fi

# A key passes when it runs an action of this configuration, the action is in
# the Custom group, and the search words of the action include the key.
problems=$(jq -r --slurpfile bindings "$TMP/bindings.json" '
	(.actions | map({ key: .name, value: . }) | from_entries) as $actions
	| $bindings[0][]
	| . as $b
	| $actions[$b.action] as $a
	| if $a == null then "\($b.key) (\($b.source)): \($b.action) is not an action of init.lua"
	  elif $a.category != "Custom" then "\($b.key) (\($b.source)): \($b.action) is not in the Custom group"
	  elif ($a.keywords | split(" ") | index($b.key)) == null then "\($b.key) (\($b.source)): the search words of \($b.action) do not include the key"
	  else empty end
' "$TMP/check.json")
count=$(jq length "$TMP/bindings.json")
if [ -z "$problems" ] && [ "$count" -gt 0 ]; then
	printf 'ok   - each of the %s keys shows in the Custom group, and the search finds it\n' "$count"
else
	echo "FAIL - a key does not show in the Custom group of the palette"
	printf '%s\n' "$problems" | sed 's/^/      /'
	fail=1
fi

exit "$fail"
