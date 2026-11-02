#!/bin/sh
# Focus the Arc window that has a given name.
# Usage: arc-focus-window.sh <window name>
#
# Aerospace focuses only that window. Do not make Arc active with AppleScript
# ("activate" or "set frontmost"), because macOS then brings all Arc windows
# to the front. In an accordion workspace, an Arc window then covers the
# window that you used.
set -eu

name="${1:?usage: arc-focus-window.sh <window name>}"
aero=/opt/homebrew/bin/aerospace
arc_bundle=company.thebrowser.Browser

# Two windows can have the same name. Prefer a window that does not have the
# focus, so that repeated calls go to the other window.
focused=$("$aero" list-windows --focused --format '%{window-id}' 2>/dev/null || true)
window=""
for id in $("$aero" list-windows --monitor all --app-bundle-id "$arc_bundle" \
  --format '%{window-id}|%{window-title}' |
  NAME="$name" awk '{
    i = index($0, "|")
    if (substr($0, i + 1) == ENVIRON["NAME"]) print substr($0, 1, i - 1)
  }'); do
  if [ -z "$window" ] || [ "$window" = "$focused" ]; then
    window=$id
  fi
done

if [ -n "$window" ]; then
  exec "$aero" focus --window-id "$window"
fi

# Aerospace lists no window with that name, for example because the title
# changed. Raise the window through the accessibility interface instead. This
# brings all Arc windows to the front, but the correct window gets the focus.
osascript - "$name" <<'EOF'
on run argv
  set wName to item 1 of argv
  tell application "System Events" to tell process "Arc"
    perform action "AXRaise" of (first window whose name is wName)
    set frontmost to true
  end tell
end run
EOF
