#!/bin/sh
# Focus an Arc space by name.
# Usage: arc-space.sh <space name>
#
# If windows already show the space, the script cycles the focus through
# them. Each call focuses the next of these windows. If no window shows the
# space, the script opens a new window and focuses the space in it.
#
# arc-focus-window.sh chooses the window and focuses it. See that script.
set -eu

target="${1:?usage: arc-space.sh <space name>}"
scripts=$(dirname "$0")
aero=/opt/homebrew/bin/aerospace
arc_bundle=company.thebrowser.Browser

# Status 3 means that no window shows the space.
rc=0
"$scripts/arc-focus-window.sh" space "$target" > /dev/null || rc=$?
[ "$rc" -eq 3 ] || exit "$rc"

arc_windows() {
  "$aero" list-windows --monitor all --app-bundle-id "$arc_bundle" --format '%{window-id}'
}

windows_before=$(arc_windows | tr '\n' ' ')

# Open a new window and focus the space in it.
osascript - "$target" <<'EOF'
on run argv
  set spaceName to item 1 of argv
  tell application "Arc"
    make new window
    repeat with s in spaces of front window
      if title of s is spaceName then
        tell s to focus
        exit repeat
      end if
    end repeat
  end tell
end run
EOF

# Arc does not report a new window to aerospace at once, so wait until
# aerospace lists it. Stop after about five seconds. The on-window-detected
# rule for Arc moves the window to workspace 1.
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
