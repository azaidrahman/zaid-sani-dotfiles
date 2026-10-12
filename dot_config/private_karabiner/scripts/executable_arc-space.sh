#!/bin/sh
# Focus an Arc space by name.
# Usage: arc-space.sh <space name>
#
# If windows already show the space, the script cycles the front position
# through them. Each call brings the next of these windows to the front.
# If no window shows the space, the script changes the space of the front
# window.

target="${1:?usage: arc-space.sh <space name>}"

osascript - "$target" <<'EOF'
on run argv
  set target to item 1 of argv
  tell application "Arc"
    activate
    -- Collect the windows that show the space. Window 1 is the front window.
    set matches to {}
    repeat with i from 1 to (count of windows)
      try
        -- Skip hidden windows. They cannot be raised, so they stop the cycle.
        if (visible of window i) and (title of active space of window i is target) then
          set end of matches to i
        end if
      end try
    end repeat

    if matches is {} then
      -- No window shows the space, so change the space of the front window.
      try
        tell front window to tell space target to focus
      end try
      return
    end if

    -- Choose the next window to put in front.
    if item 1 of matches is 1 and (count of matches) > 1 then
      -- The front window already shows the space. Go to the window that is
      -- furthest back, which makes repeated calls cycle through all of them.
      -- With one match, raise that window anyway: a floating window from
      -- another app can cover it.
      set pick to item (count of matches) of matches
    else
      set pick to item 1 of matches
    end if

    set wName to name of window pick
  end tell

  -- Arc cannot raise a window through AppleScript, so use the accessibility
  -- interface. Prefer a window that is not in front, because two windows can
  -- have the same name.
  tell application "System Events" to tell process "Arc"
    try
      set candidates to (every window whose name is wName)
      if (count of candidates) is 0 then return
      set w to item 1 of candidates
      if (count of candidates) > 1 and name of window 1 is wName then
        set w to item 2 of candidates
      end if
      perform action "AXRaise" of w
    end try
  end tell
  return
end run
EOF
