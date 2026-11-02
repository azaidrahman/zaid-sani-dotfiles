#!/bin/sh
# Focus a named tab in an Arc space.
# Usage: arc-tab.sh <space name> <tab title>
#
# Arc shares its spaces between all windows. If a window already shows the
# space, the script opens the tab in that window. Otherwise it uses the front
# Arc window, which then changes to the space.
#
# Aerospace gives the focus to the window, not AppleScript. If AppleScript
# makes Arc active, macOS brings all Arc windows to the front. See
# arc-focus-window.sh.
set -eu

space_name="${1:?usage: arc-tab.sh <space name> <tab title>}"
tab_title="${2:?usage: arc-tab.sh <space name> <tab title>}"

# Choose the window and print its Arc id. This step changes nothing. Do not
# use the name of the window. Two windows can have the same name, and the
# name changes when the tab changes.
window_id=$(osascript - "$space_name" "$tab_title" <<'EOF'
on run argv
  set spaceName to item 1 of argv
  set tabTitle to item 2 of argv
  -- Arc reports some windows that are not on screen. Count only the windows
  -- that the accessibility interface can see, because only those can get
  -- the focus.
  tell application "System Events" to tell process "Arc"
    set axNames to name of every window
  end tell
  tell application "Arc"
    set wId to ""
    set frontId to ""
    -- Iterate, because index references such as window 1 fail in Arc.
    repeat with w in windows
      try
        if (visible of w) and (axNames contains (name of w)) then
          if frontId is "" then set frontId to id of w
          if title of active space of w is spaceName then
            set wId to id of w
            exit repeat
          end if
        end if
      end try
    end repeat
    if wId is "" then set wId to frontId
    if wId is "" then error "No Arc window can get the focus"
  end tell
  return wId
end run
EOF
)

# Focus the window before the tab changes. arc-focus-window.sh finds the
# aerospace window by its title, and the title changes with the tab.
"$(dirname "$0")/arc-focus-window.sh" "$window_id" || true

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
