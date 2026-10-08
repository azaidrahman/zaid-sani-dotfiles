#!/bin/sh
# Focus a named tab in an Arc space.
# Usage: arc-tab.sh <space name> <tab title>
set -eu

space_name="${1:?usage: arc-tab.sh <space name> <tab title>}"
tab_title="${2:?usage: arc-tab.sh <space name> <tab title>}"

osascript - "$space_name" "$tab_title" <<'EOF'
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
              activate
              set windowName to name of w
              tell application "System Events" to tell process "Arc"
                perform action "AXRaise" of (first window whose name is windowName)
              end tell
              return
            end if
          end repeat
        end if
      end repeat
    end repeat
  end tell
  error "Arc tab not found: " & spaceName & " / " & tabTitle
end run
EOF
