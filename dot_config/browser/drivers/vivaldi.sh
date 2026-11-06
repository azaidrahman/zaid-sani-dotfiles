# shellcheck shell=bash disable=SC2034 # The browser command uses DRIVER_*.
# The driver for Vivaldi. The browser command sources this file.
#
# A space is a Vivaldi workspace. All workspaces are in one Vivaldi profile.
# vivaldi.js does the work that needs Vivaldi scripting.
#
# Results of the checks on Vivaldi 8.2 (2026-11-05):
# 1. "tabs of window" gives the tabs of all workspaces.
# 2. If a script activates a tab of a different workspace, Vivaldi shows the
#    tab for about 2 seconds, then goes back to a tab of the active workspace.
#    Thus the driver shows the workspace of the tab first. Vivaldi scripting
#    does not tell the workspace of a tab, so vivaldi.js finds it with the
#    workspace rules of Vivaldi.
# 3. Vivaldi shows a workspace when it gets ⌃⇧N (the default shortcuts).
#    ⌃⇧1 shows the tabs that are in no workspace, ⌃⇧2 shows the first
#    workspace, and so on. Vivaldi must be the frontmost application. After
#    AeroSpace focuses the window, wait until macOS makes Vivaldi frontmost,
#    then send the keys. Keys sent before that go to the old application.
# 5. Not checked: there is one main Vivaldi window.
# 6. The workspace rules also move links from other applications and URLs
#    that the user types. Vivaldi then shows the workspace of the tab.
# 7. A private window has no workspaces, so it ignores ⌃⇧N. AeroSpace shows
#    the same title format for a private window. Only Vivaldi scripting can
#    find a private window: its "mode" is "incognito", not "normal".
# 8. The title of the active tab in Vivaldi scripting can differ from the
#    title that AeroSpace shows. The start page has an empty title in
#    scripting, but AeroSpace shows "Start Page - Vivaldi". The view of the
#    tabs in no workspace often shows the start page.
#
# AeroSpace shows a Vivaldi window as "<title of the active tab> - Vivaldi".
# A Picture in Picture window is also a Vivaldi window. The driver ignores it.

DRIVER_APP=Vivaldi
DRIVER_BUNDLE=com.vivaldi.Vivaldi

VIVALDI_PREFS="${VIVALDI_PREFS:-$HOME/Library/Application Support/Vivaldi/Default/Preferences}"

# The key codes of the digit keys 1 to 9.
viv_digit_codes="18 19 20 21 23 22 26 28 25"

# viv_js <command> [<arguments>]: run vivaldi.js.
viv_js() {
  osascript -l JavaScript "$BROWSER_HOME/drivers/vivaldi.js" "$VIVALDI_PREFS" "$@"
}

# viv_main_window: print the AeroSpace id of the main Vivaldi window. This is
# the front window that is not private (see check 7). If Vivaldi has no
# window, or has only private windows, open a window.
viv_main_window() {
  local list wins id before
  list=$("$AEROSPACE_BIN" list-windows --monitor all --app-bundle-id "$DRIVER_BUNDLE" \
    --format '%{window-id}|%{window-title}' | grep -v '|Picture in Picture$')
  if [ -z "$list" ]; then
    before=$(aero_ids | tr '\n' ' ')
    open -b "$DRIVER_BUNDLE" || return 1
    aero_wait_new "$before"
    return
  fi
  # Vivaldi lists its windows from front to back. Print one line for each
  # window: the mode, a tab, and the title of the active tab. In a tell block
  # for Vivaldi, "tab" is a tab of the browser, so use "character id 9".
  if ! wins=$(osascript -e 'tell application "Vivaldi"' -e 'set out to ""' \
    -e 'repeat with w in windows' \
    -e 'set out to out & (mode of w) & (character id 9) & (title of active tab of w) & linefeed' \
    -e 'end repeat' -e 'end tell' -e 'return out'); then
    printf '%s\n' "$list" | head -n 1 | cut -d'|' -f1
    return 0
  fi
  if ! printf '%s\n' "$wins" | grep -q '^normal	'; then
    before=$(aero_ids | tr '\n' ' ')
    osascript -e 'tell application "Vivaldi" to make new window with properties {mode:"normal"}' \
      > /dev/null || return 1
    aero_wait_new "$before"
    return
  fi
  # Pair each Vivaldi window with the first free AeroSpace window that shows
  # its title. If the main window has no pair (see check 8), use a window that
  # has no pair. Never use a window that pairs with a private window. Split
  # each AeroSpace line at the first "|" only: a title can contain "|".
  id=$({
    printf '%s\n' "$wins" | sed 's/^/V/'
    printf '%s\n' "$list" | sed 's/^/A/'
  } | awk '
    /^V/ {
      t = index($0, "\t"); if (!t) next
      n++; mode[n] = substr($0, 2, t - 2); want[n] = substr($0, t + 1) " - Vivaldi"
      next
    }
    /^A/ {
      i = index($0, "|"); if (!i) next
      m++; wid[m] = substr($0, 2, i - 2); title[m] = substr($0, i + 1)
    }
    END {
      for (v = 1; v <= n; v++) {
        if (!main && mode[v] == "normal") main = v
        for (a = 1; a <= m; a++)
          if (!owner[a] && title[a] == want[v]) { owner[a] = v; pair[v] = a; break }
      }
      if (pair[main]) { print wid[pair[main]]; exit }
      for (a = 1; a <= m; a++) if (!owner[a]) { print wid[a]; exit }
      for (a = 1; a <= m; a++) if (mode[owner[a]] == "normal") { print wid[a]; exit }
    }')
  if [ -z "$id" ]; then
    echo "cannot find the main Vivaldi window" >&2
    return 1
  fi
  echo "$id"
}

# viv_focus_main: focus the main Vivaldi window.
viv_focus_main() {
  local window
  window=$(viv_main_window) || return 1
  aero_focus "$window"
}

# viv_show <position>: focus the main window, and show the workspace at the
# position (1 is the first workspace).
viv_show() {
  viv_focus_main || return 1
  viv_key "$1"
}

# viv_key <position>: send the shortcut for the workspace at the position to
# the focused Vivaldi window. Send it as soon as Vivaldi is the frontmost
# application. If Vivaldi does not become frontmost in 1 second, stop, so
# that the keys never go to a different application.
viv_key() {
  local digit=$(($1 + 1)) code
  if [ "$digit" -gt 9 ]; then
    echo "no shortcut for workspace $1" >&2
    return 1
  fi
  code=$(echo "$viv_digit_codes" | cut -d' ' -f"$digit")
  osascript - "$code" <<'EOF'
on run argv
  tell application "System Events"
    set tries to 0
    repeat until frontmost of process "Vivaldi"
      set tries to tries + 1
      if tries > 40 then error "Vivaldi is not the frontmost application"
      delay 0.025
    end repeat
    key code (item 1 of argv as integer) using {control down, shift down}
  end tell
end run
EOF
}

# viv_position <name>: print the position of the workspace (1 is the first),
# or 0. Read the Preferences file with plutil, because it is faster than
# vivaldi.js.
viv_position() {
  plutil -extract vivaldi.workspaces.list json -o - "$VIVALDI_PREFS" 2>/dev/null |
    grep -o '"name":"[^"]*"' |
    awk -v want="\"name\":\"$1\"" '$0 == want { print NR; found = 1; exit } END { if (!found) print 0 }'
}

# drv_no_space: show the tabs that are in no workspace. The key for position 0
# is ⌃⇧1.
drv_no_space() {
  viv_show 0
}

# drv_space <name> <index>
drv_space() {
  local pos
  pos=$(viv_position "$1")
  if [ "$pos" -eq 0 ]; then
    echo "Vivaldi has no workspace $1" >&2
    return 1
  fi
  viv_show "$pos"
}

# drv_space_window <name> <index>: show the workspace in a new window. After
# the key, one of two things occurs:
# - The new window keeps the focus and shows the workspace. Keep the window.
#   If the workspace has no tabs in the new window, the window shows only a
#   start page. Keep it also then: the user asked for that window.
# - Vivaldi focuses a different window that shows the workspace. The new
#   window then keeps only its start page. Close the new window. Close it by
#   its Vivaldi id, and only if it still has only its start page: never close
#   a window that holds tabs of the user.
# Thus the focus, not the tabs, tells if the new window shows the workspace.
drv_space_window() {
  local pos before win new
  pos=$(viv_position "$1")
  if [ "$pos" -eq 0 ]; then
    echo "Vivaldi has no workspace $1" >&2
    return 1
  fi
  # If Vivaldi is not running, "make new window" starts it, and Vivaldi also
  # opens its last session. Start it first, so that the new window is the
  # only window that is new.
  if ! pgrep -x Vivaldi > /dev/null; then
    viv_focus_main || return 1
  fi
  before=$(aero_ids | tr '\n' ' ')
  win=$(osascript -e 'tell application "Vivaldi" to get id of (make new window)') || return 1
  new=$(aero_wait_new "$before") || return 1
  aero_focus "$new" || return 1
  viv_key "$pos" || return 1
  sleep 0.4
  if [ "$("$AEROSPACE_BIN" list-windows --focused --format '%{window-id}')" = "$new" ]; then
    return 0
  fi
  if [ "$(viv_js window-empty "$win")" = yes ]; then
    osascript - "$win" <<'EOF'
on run argv
  set wId to item 1 of argv
  tell application "Vivaldi"
    repeat with w in windows
      if (id of w as text) is wId then
        close w
        return
      end if
    end repeat
  end tell
end run
EOF
  fi
}

# viv_focus_tab <tab id> <position>: show the workspace at the position, if it
# is not 0, then activate the tab.
viv_focus_tab() {
  if [ "$2" -gt 0 ]; then
    viv_show "$2" || return 1
  else
    viv_focus_main || return 1
  fi
  viv_js activate "$1" > /dev/null
}

# drv_focus_url <prefix> <url> [<space>]: focus the first tab whose URL starts
# with the prefix. If no tab matches, open the URL. The workspace rules of
# Vivaldi put the new tab in its workspace. The space is the workspace to show
# when no workspace rule matches the tab.
drv_focus_url() {
  local found
  found=$(viv_js find "$1" "${3:-}") || return 1
  if [ -z "$found" ]; then
    open -b "$DRIVER_BUNDLE" "$2"
    return
  fi
  viv_focus_tab "${found%%	*}" "${found#*	}"
}

# drv_open_in <space> <index> <url>: show the workspace, then focus the tab
# of the URL in it. If the workspace has no such tab, open the URL there: a
# new tab opens in the workspace that Vivaldi shows, unless a workspace rule
# sends it to a different one.
drv_open_in() {
  local pos found
  pos=$(viv_position "$1")
  if [ "$pos" -eq 0 ]; then
    echo "Vivaldi has no workspace $1" >&2
    return 1
  fi
  viv_show "$pos" || return 1
  found=$(viv_js find-in "$3" "$pos") || return 1
  if [ -n "$found" ]; then
    viv_js activate "$found" > /dev/null
  else
    open -b "$DRIVER_BUNDLE" "$3"
  fi
}

# drv_tab <name> <space> <url prefix>
drv_tab() {
  drv_focus_url "$3" "$3" "$2"
}

# drv_tabs: Alfred runs this at each key press. Do not start Vivaldi.
drv_tabs() {
  if ! pgrep -x Vivaldi > /dev/null; then
    printf '{"items":[{"title":"Vivaldi is not running","valid":false}]}\n'
    return 0
  fi
  viv_js tabs
}

# drv_current_space: print the workspace of the front window, or nothing.
# Alfred runs this at each key press. Do not start Vivaldi.
drv_current_space() {
  pgrep -x Vivaldi > /dev/null || return 0
  viv_js current
}

# drv_focus_tab <window id> <tab id>
drv_focus_tab() {
  local pos
  pos=$(viv_js tab-position "$2") || return 1
  viv_focus_tab "$2" "$pos"
}
