#!/bin/sh
# Focus an Arc space by name.
# Usage: arc-space.sh <space name>
#
# If windows already show the space, the script cycles the focus through
# them. Each call focuses the next of these windows. If no window shows the
# space, the script opens a new window and focuses the space in it.
#
# Aerospace gives the focus to the window, not AppleScript. If AppleScript
# makes Arc active, macOS brings all Arc windows to the front. See
# arc-focus-window.sh.
set -eu

target="${1:?usage: arc-space.sh <space name>}"
scripts=$(dirname "$0")
aero=/opt/homebrew/bin/aerospace
arc_bundle=company.thebrowser.Browser

arc_windows() {
  "$aero" list-windows --monitor all --app-bundle-id "$arc_bundle" --format '%{window-id}'
}

windows_before=$(arc_windows | tr '\n' ' ')

# The AppleScript prints the name of the window to focus. If it opens a new
# window, it prints nothing.
wName=$(osascript - "$target" <<'EOF'
on run argv
  set spaceName to item 1 of argv
  -- Arc reports some windows that are not on screen. Count only the windows
  -- that the accessibility interface can see, because only those can get
  -- the focus.
  tell application "System Events" to tell process "Arc"
    set axNames to name of every window
  end tell
  tell application "Arc"
    -- Collect the names of the windows that show the space, front window
    -- first. Index references such as window 1 fail in Arc, so iterate.
    set matches to {}
    set frontShows to false
    set k to 0
    repeat with w in windows
      set k to k + 1
      try
        -- Skip hidden windows. They cannot get the focus, so they stop the
        -- cycle.
        if (visible of w) and (title of active space of w is spaceName) and (axNames contains (name of w)) then
          set end of matches to (name of w)
          if k is 1 then set frontShows to true
        end if
      end try
    end repeat

    if matches is {} then
      -- No window shows the space, so open a new window and focus the space
      -- in it.
      make new window
      repeat with s in spaces of front window
        if title of s is spaceName then
          tell s to focus
          exit repeat
        end if
      end repeat
      return ""
    end if

    if frontShows and (count of matches) > 1 then
      -- The front window already shows the space. Go to the window that is
      -- furthest back, which makes repeated calls cycle through all of them.
      return item (count of matches) of matches
    end if
    -- With one match, focus that window anyway: a floating window from
    -- another app can cover it.
    return item 1 of matches
  end tell
end run
EOF
)

if [ -n "$wName" ]; then
  exec "$scripts/arc-focus-window.sh" "$wName"
fi

# The AppleScript opened a new window. Arc does not report a new window to
# aerospace at once, so wait until aerospace lists it. Stop after about five
# seconds. The on-window-detected rule for Arc moves the window to
# workspace 1.
attempt=0
while [ "$attempt" -lt 50 ]; do
  for id in $(arc_windows); do
    case " $windows_before " in
      *" $id "*) ;;
      *) exec "$aero" focus --window-id "$id" ;;
    esac
  done
  sleep 0.1
  attempt=$((attempt + 1))
done
echo "arc-space: the new Arc window was not found" >&2
exit 1
