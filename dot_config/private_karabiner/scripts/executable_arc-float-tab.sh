#!/bin/sh
# Open a URL in a new, floating Arc window. If a window that this script made
# is still open, focus it instead of making another one.
# Usage: arc-float-tab.sh <url>
#
# The window is temporary. It is a new Arc window, not a saved space, so it
# is not kept in the sidebar. Close the window when you are done.
#
# Arc does not report a new window to aerospace by itself. The script lists
# the Arc windows before and after it makes the new one, then floats the
# window that is new. It keeps the aerospace ids of the windows it made in a
# state file, so it only focuses windows that it made itself.
set -eu

url="${1:?usage: arc-float-tab.sh <url>}"
aero=/opt/homebrew/bin/aerospace
arc_bundle=company.thebrowser.Browser
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/arc-float-tab"
state_file="$state_dir/windows"
mkdir -p "$state_dir"
touch "$state_file"

open_ids=$("$aero" list-windows --monitor all --app-bundle-id "$arc_bundle" --format '%{window-id}')

# Focus the first window that this script made and that is still open. Keep
# only the ids that are still open, so the state file does not grow.
existing=""
kept=""
for id in $(cat "$state_file"); do
  if printf '%s\n' "$open_ids" | grep -qx "$id"; then
    kept="$kept$id
"
    [ -z "$existing" ] && existing=$id
  fi
done
printf '%s' "$kept" > "$state_file"

if [ -n "$existing" ]; then
  "$aero" focus --window-id "$existing"
  exit 0
fi

windows_before=$(printf '%s\n' "$open_ids" | tr '\n' ' ')

osascript - "$url" <<'EOF'
on run argv
  set targetURL to item 1 of argv
  tell application "Arc"
    -- A new tab with a URL opens in a new Arc window. Making a window with
    -- "make new window" leaves no tab that scripts can reach.
    make new tab at end of tabs of window 1 with properties {URL:targetURL}
  end tell
end run
EOF

# Wait until aerospace lists the new window. Stop after about five seconds.
new_window=""
attempt=0
while [ -z "$new_window" ] && [ "$attempt" -lt 50 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
  for id in $("$aero" list-windows --monitor all --app-bundle-id "$arc_bundle" --format '%{window-id}'); do
    case " $windows_before " in
      *" $id "*) ;;
      *) new_window=$id ;;
    esac
  done
done

if [ -z "$new_window" ]; then
  echo "arc-float-tab: the new Arc window was not found" >&2
  exit 1
fi

# Remember the window, so the next press focuses it.
printf '%s\n' "$new_window" >> "$state_file"

# Move the window to the workspace in use, then float it and focus it.
# The on-window-detected rule for Arc moves new windows to workspace 1.
"$aero" move-node-to-workspace --window-id "$new_window" "$("$aero" list-workspaces --focused)"
"$aero" layout --window-id "$new_window" floating
"$aero" focus --window-id "$new_window"
