#!/bin/sh
# Focus one Arc window through aerospace.
# Usage: arc-focus-window.sh <Arc window id>
#
# The Arc window id is the "id" property of an Arc window in AppleScript.
#
# Aerospace focuses only that window. Do not make Arc active with AppleScript
# ("activate" or "set frontmost"), because macOS then brings all Arc windows
# to the front. In an accordion workspace, an Arc window then covers the
# window that you used.
#
# Arc and aerospace use different window ids. The only value that both show
# is the title of the window, which is the title of its active tab. Two
# windows can have the same title, for example two lessons on the same site.
# If the title is not unique, the position from front to back finds the
# window. Arc and macOS keep the Arc windows in the same order.
set -eu

arc_id="${1:?usage: arc-focus-window.sh <Arc window id>}"
aero=${AEROSPACE_BIN:-/opt/homebrew/bin/aerospace}
arc_bundle=company.thebrowser.Browser
tries=${ARC_FOCUS_TRIES:-10}
tab=$(printf '\t')

# Print "<rank><TAB><title>" for the window. The rank is the number of Arc
# windows with the same title that are in front of the window.
window_info() {
  osascript - "$arc_id" <<'EOF'
on run argv
  set targetId to item 1 of argv
  -- Arc reports some windows that are not on screen. Aerospace does not list
  -- them, so do not count them.
  tell application "System Events" to tell process "Arc"
    set axNames to name of every window
  end tell
  tell application "Arc"
    set targetName to missing value
    set frontNames to {}
    -- Arc gives the windows from front to back. Index references such as
    -- window 1 fail in Arc, so iterate.
    repeat with w in windows
      if targetName is missing value then
        try
          if (id of w) is targetId then
            set targetName to name of w
          else if (visible of w) and (axNames contains (name of w)) then
            set end of frontNames to (name of w)
          end if
        end try
      end if
    end repeat
  end tell
  if targetName is missing value then error "No Arc window has the id " & targetId
  set rank to 0
  repeat with n in frontNames
    if contents of n is targetName then set rank to rank + 1
  end repeat
  return (rank as text) & tab & targetName
end run
EOF
}

# Make the window with the aerospace id $1 and the title $2 the main window
# of Arc, and raise it. This does not make Arc active.
#
# If Arc is not active, "aerospace focus" makes it active. Arc then gives the
# focus to the Arc window that you used last, not to the window that
# aerospace focuses. About one time in three, that other window wins. If the
# window is already the main window, Arc keeps it.
#
# System Events finds the window, because Karabiner can use System Events.
# Two windows can have the same title, so also compare the position of the
# window with the position that macOS gives for the aerospace id.
make_main() {
  osascript -l JavaScript - "$1" "$2" <<'EOF'
ObjC.import('CoreGraphics');
function run(argv) {
  const id = parseInt(argv[0], 10);
  const info = ObjC.deepUnwrap(ObjC.castRefToObject(
    $.CGWindowListCopyWindowInfo($.kCGWindowListOptionIncludingWindow, id)));
  if (!info || info.length === 0) return;
  const b = info[0].kCGWindowBounds;
  const wins = Application('System Events').processes.byName('Arc')
    .windows.whose({ name: argv[1] })();
  let w = wins.find(c => {
    const p = c.position();
    return Math.round(p[0]) === Math.round(b.X) && Math.round(p[1]) === Math.round(b.Y);
  });
  if (!w && wins.length === 1) w = wins[0];
  if (!w) return;
  w.attributes.byName('AXMain').value = true;
  w.actions.byName('AXRaise').perform();
}
EOF
}

# Focus the window with the aerospace id $1. If make_main fails, aerospace
# still focuses the window, so ignore the error.
focus_window() {
  make_main "$1" "$name" > /dev/null 2>&1 || true
  exec "$aero" focus --window-id "$1"
}

# Print the aerospace ids of the Arc windows, front to back.
stacking_order() {
  osascript -l JavaScript - <<'EOF'
ObjC.import('CoreGraphics');
function run() {
  const all = ObjC.deepUnwrap(ObjC.castRefToObject(
    $.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0)));
  return all
    .filter(w => w.kCGWindowOwnerName === 'Arc' && w.kCGWindowLayer === 0)
    .map(w => w.kCGWindowNumber)
    .join('\n');
}
EOF
}

attempt=1
while :; do
  info=$(window_info)
  rank=${info%%"$tab"*}
  name=${info#*"$tab"}

  candidates=$("$aero" list-windows --monitor all --app-bundle-id "$arc_bundle" \
    --format '%{window-id}|%{window-title}' |
    NAME="$name" awk '{
      i = index($0, "|")
      if (substr($0, i + 1) == ENVIRON["NAME"]) print substr($0, 1, i - 1)
    }')

  case $(printf '%s\n' "$candidates" | grep -c .) in
    0) ;;
    1) focus_window "$candidates" ;;
    *)
      # Go through the windows from front to back. Take the window at the
      # rank among the windows that have the title. If the order does not
      # have enough of them, take the last one.
      window=$(stacking_order | CANDIDATES="$candidates" RANK="$rank" awk '
        BEGIN { n = split(ENVIRON["CANDIDATES"], c, "\n"); for (i = 1; i <= n; i++) want[c[i]] = 1 }
        ($1 in want) && !($1 in seen) {
          seen[$1] = 1; last = $1
          if (found++ == ENVIRON["RANK"] + 0) { print $1; done = 1; exit }
        }
        END { if (!done) print (last != "" ? last : c[1]) }')
      focus_window "$window"
      ;;
  esac

  # Aerospace lists no window with the title. The title can change while a
  # page loads, so read it again. Do not raise the window through the
  # accessibility interface, because that brings all Arc windows to the front.
  if [ "$attempt" -ge "$tries" ]; then
    echo "arc-focus-window: aerospace lists no Arc window with the title: $name" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
