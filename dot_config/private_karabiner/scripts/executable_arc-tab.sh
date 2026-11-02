#!/bin/sh
# Focus a named tab in an Arc space.
# Usage: arc-tab.sh <space name> <tab title>
#
# Arc shares its spaces between all windows. If a window already shows the
# space, the script opens the tab in that window. Otherwise it uses the front
# Arc window, which then changes to the space.
#
# arc-focus-window.sh chooses the window and focuses it. See that script.
set -eu

space_name="${1:?usage: arc-tab.sh <space name> <tab title>}"
tab_title="${2:?usage: arc-tab.sh <space name> <tab title>}"

# Focus the window before the tab changes. arc-focus-window.sh finds the
# aerospace window by its title, and the title changes with the tab. The
# script prints the Arc id of the window. Do not use the name of the window
# to find it again, because two windows can have the same name.
window_id=$("$(dirname "$0")/arc-focus-window.sh" tab "$space_name") || true

# Select the tab in the window that has that id.
osascript - "$window_id" "$space_name" "$tab_title" <<'EOF'
on run argv
  set wId to item 1 of argv
  set spaceName to item 2 of argv
  set tabTitle to item 3 of argv
  tell application "Arc"
    repeat with w in windows
      set isTarget to false
      try
        set isTarget to (id of w is wId)
      end try
      if isTarget then
        repeat with s in spaces of w
          if title of s is spaceName then
            repeat with t in tabs of s
              if title of t is tabTitle then
                tell s to focus
                tell t to select
                return
              end if
            end repeat
          end if
        end repeat
      end if
    end repeat
  end tell
  error "Arc tab not found: " & spaceName & " / " & tabTitle
end run
EOF
