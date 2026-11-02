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

# Choose the window and print its name. This step changes nothing.
window_name=$(osascript - "$space_name" "$tab_title" <<'EOF'
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
    set wName to ""
    set frontName to ""
    -- Iterate, because index references such as window 1 fail in Arc.
    repeat with w in windows
      try
        if (visible of w) and (axNames contains (name of w)) then
          if frontName is "" then set frontName to name of w
          if title of active space of w is spaceName then
            set wName to name of w
            exit repeat
          end if
        end if
      end try
    end repeat
    if wName is "" then set wName to frontName
    if wName is "" then error "No Arc window can get the focus"
  end tell
  return wName
end run
EOF
)

# Focus the window before the tab changes. The name of a window is the title
# of its active tab, so a different tab gives the window a different name.
"$(dirname "$0")/arc-focus-window.sh" "$window_name" || true

# Select the tab in the window that has that name.
osascript - "$window_name" "$space_name" "$tab_title" <<'EOF'
on run argv
  set wName to item 1 of argv
  set spaceName to item 2 of argv
  set tabTitle to item 3 of argv
  tell application "Arc"
    repeat with w in windows
      set isTarget to false
      try
        set isTarget to (visible of w) and (name of w is wName)
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
