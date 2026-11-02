#!/bin/sh
# Focus a named tab in an Arc space.
# Usage: arc-tab.sh <space name> <tab title>
#
# Aerospace gives the focus to the window, not AppleScript. If AppleScript
# makes Arc active, macOS brings all Arc windows to the front. See
# arc-focus-window.sh.
set -eu

space_name="${1:?usage: arc-tab.sh <space name> <tab title>}"
tab_title="${2:?usage: arc-tab.sh <space name> <tab title>}"

# The AppleScript selects the tab and prints the name of its window.
window_name=$(osascript - "$space_name" "$tab_title" <<'EOF'
on run argv
  set spaceName to item 1 of argv
  set tabTitle to item 2 of argv
  tell application "Arc"
    repeat with w in windows
      repeat with s in spaces of w
        if title of s is spaceName then
          repeat with t in tabs of s
            if title of t is tabTitle then
              tell s to focus
              tell t to select
              return name of w
            end if
          end repeat
        end if
      end repeat
    end repeat
  end tell
  error "Arc tab not found: " & spaceName & " / " & tabTitle
end run
EOF
)

exec "$(dirname "$0")/arc-focus-window.sh" "$window_name"
