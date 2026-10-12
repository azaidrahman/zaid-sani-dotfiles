#!/bin/sh
# Focus an Arc space by name.
# Usage: arc-space.sh <space name>
#
# If windows already show the space, the script cycles the front position
# through them. Each call brings the next of these windows to the front.
# If no window shows the space, the script opens a new window and focuses
# the space in it.

target="${1:?usage: arc-space.sh <space name>}"

osascript - "$target" <<'EOF'
on run argv
  set spaceName to item 1 of argv
  -- Arc reports some windows that are not on screen. Count only the windows
  -- that the accessibility interface can see, because only those can be raised.
  tell application "System Events" to tell process "Arc"
    set axNames to name of every window
  end tell
  tell application "Arc"
    activate
    -- Collect the names of the windows that show the space, front window
    -- first. Index references such as window 1 fail in Arc, so iterate.
    set matches to {}
    set frontShows to false
    set k to 0
    repeat with w in windows
      set k to k + 1
      try
        -- Skip hidden windows. They cannot be raised, so they stop the cycle.
        if (visible of w) and (title of active space of w is spaceName) and (axNames contains (name of w)) then
          set end of matches to (name of w)
          if k is 1 then set frontShows to true
        end if
      end try
    end repeat

    if matches is {} then
      -- No window shows the space, so open a new window and focus the space
      -- in it. The new window becomes the front window.
      make new window
      repeat with s in spaces of front window
        if title of s is spaceName then
          tell s to focus
          exit repeat
        end if
      end repeat
      return
    end if

    -- Choose the next window to put in front.
    if frontShows and (count of matches) > 1 then
      -- The front window already shows the space. Go to the window that is
      -- furthest back, which makes repeated calls cycle through all of them.
      set wName to item (count of matches) of matches
    else
      -- With one match, raise that window anyway: a floating window from
      -- another app can cover it.
      set wName to item 1 of matches
    end if
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
