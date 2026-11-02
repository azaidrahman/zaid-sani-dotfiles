#!/bin/sh
# Focus one Arc window through aerospace.
# Usage: arc-focus-window.sh space <space name>
#        arc-focus-window.sh tab <space name>
#
# space: Focus a window that shows the space. If the front window shows the
#        space and other windows also show it, focus the window that is
#        furthest back. Thus repeated calls cycle through these windows. If
#        no window shows the space, exit with status 3.
# tab:   Focus the window that shows the space. If no window shows the space,
#        focus the front Arc window.
#
# Both modes print the Arc id of the window. The Arc id is the "id" property
# of an Arc window in AppleScript.
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
#
# The script asks Arc only one time, because each osascript call adds about
# 100 ms to the key press.
set -eu

mode="${1:?usage: arc-focus-window.sh space|tab <space name>}"
space="${2:?usage: arc-focus-window.sh space|tab <space name>}"
aero=${AEROSPACE_BIN:-/opt/homebrew/bin/aerospace}
arc_bundle=company.thebrowser.Browser
tries=${ARC_FOCUS_TRIES:-10}
tab=$(printf '\t')

# arc_query <mode> <space name or Arc id>
# Choose the window, and print "<Arc id><TAB><rank><TAB><main><TAB><title>".
# The rank is the number of Arc windows with the same title that are in front
# of the window. Mode "id" chooses the window that has the Arc id.
#
# If Arc is not active, "aerospace focus" makes it active. Arc then gives the
# focus to the Arc window that you used last, not to the window that
# aerospace focuses. About one time in three, that other window wins. If the
# window is already the main window of Arc, Arc keeps it. Thus, if no other
# window has the title, the query makes the window the main window and
# raises it. This does not make Arc active. Then <main> is 1.
#
# If no window matches, print nothing.
arc_query() {
  osascript - "$1" "$2" <<'EOF'
on run argv
  set queryMode to item 1 of argv
  set arg to item 2 of argv
  -- Arc reports some windows that are not on screen. Aerospace does not list
  -- them, and they cannot get the focus. Skip them.
  tell application "System Events" to tell process "Arc"
    set axNames to name of every window
  end tell
  set ids to {}
  set names to {}
  set spaceNames to {}
  tell application "Arc"
    -- Arc gives the windows from front to back. Index references such as
    -- window 1 fail in Arc, so iterate.
    repeat with w in windows
      try
        set wName to name of w
        if (visible of w) and (axNames contains wName) then
          set sName to ""
          try
            set sName to title of active space of w
          end try
          set end of ids to (id of w)
          set end of names to wName
          set end of spaceNames to sName
        end if
      end try
    end repeat
  end tell

  set k to 0
  if queryMode is "id" then
    repeat with i from 1 to count of ids
      if item i of ids is arg then
        set k to i
        exit repeat
      end if
    end repeat
  else
    set matches to {}
    repeat with i from 1 to count of ids
      if item i of spaceNames is arg then set end of matches to i
    end repeat
    if matches is not {} then
      set k to item 1 of matches
      -- The front window already shows the space. Go to the window that is
      -- furthest back, which makes repeated calls cycle through all of them.
      if queryMode is "space" and k is 1 and (count of matches) > 1 then set k to item -1 of matches
    else if queryMode is "tab" and ids is not {} then
      set k to 1
    end if
  end if
  if k is 0 then return ""

  set targetName to item k of names
  set rank to 0
  repeat with i from 1 to k - 1
    if item i of names is targetName then set rank to rank + 1
  end repeat
  set sameName to 0
  repeat with n in axNames
    if contents of n is targetName then set sameName to sameName + 1
  end repeat
  set isMain to 0
  if sameName is 1 then
    try
      tell application "System Events" to tell process "Arc"
        set w to first window whose name is targetName
        set value of attribute "AXMain" of w to true
        perform action "AXRaise" of w
      end tell
      set isMain to 1
    end try
  end if
  return (item k of ids) & tab & (rank as text) & tab & (isMain as text) & tab & targetName
end run
EOF
}

# make_main <aerospace id> <title>
# Make the window the main window of Arc, and raise it. arc_query does this
# when the title is unique. If the title is not unique, compare the position
# of each window that has the title with the position that macOS gives for
# the aerospace id. System Events finds the window, because Karabiner can use
# System Events.
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

# Read the fields of the output of arc_query.
parse() {
  arc_id=${1%%"$tab"*}
  rest=${1#*"$tab"}
  rank=${rest%%"$tab"*}
  rest=${rest#*"$tab"}
  is_main=${rest%%"$tab"*}
  name=${rest#*"$tab"}
}

# Focus the window with the aerospace id $1. If make_main fails, aerospace
# still focuses the window, so ignore the error.
focus_window() {
  if [ "$is_main" != 1 ]; then
    make_main "$1" "$name" > /dev/null 2>&1 || true
  fi
  exec "$aero" focus --window-id "$1"
}

info=$(arc_query "$mode" "$space")
if [ -z "$info" ]; then
  [ "$mode" = space ] && exit 3
  echo "arc-focus-window: no Arc window can get the focus" >&2
  exit 1
fi
parse "$info"
printf '%s\n' "$arc_id"

attempt=1
while :; do
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
  info=$(arc_query id "$arc_id")
  [ -n "$info" ] || exit 1
  parse "$info"
done
