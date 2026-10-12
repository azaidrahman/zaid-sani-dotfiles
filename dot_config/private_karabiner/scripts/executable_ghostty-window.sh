#!/bin/sh
# Focus a Ghostty window.
# If Ghostty is not the frontmost app, bring the front window to the front.
# If Ghostty is already the frontmost app, bring the window furthest back to
# the front. Repeated calls cycle through all windows.
# If Ghostty has no window, open Ghostty.

osascript - <<'EOF'
on run argv
  tell application "Ghostty"
    set windowCount to count of windows
    set isFront to frontmost
  end tell

  if windowCount is 0 then
    do shell script "open -a Ghostty"
    return
  end if

  tell application "Ghostty"
    if isFront then
      activate window window windowCount
    else
      activate window window 1
    end if
  end tell
end run
EOF
