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

# viv_main_window: print the AeroSpace id of the main Vivaldi window. If
# Vivaldi has no window, open one.
viv_main_window() {
  local list title id
  list=$("$AEROSPACE_BIN" list-windows --monitor all --app-bundle-id "$DRIVER_BUNDLE" \
    --format '%{window-id}|%{window-title}' | grep -v '|Picture in Picture$')
  if [ -z "$list" ]; then
    local before
    before=$(aero_ids | tr '\n' ' ')
    open -b "$DRIVER_BUNDLE" || return 1
    aero_wait_new "$before"
    return
  fi
  if [ "$(printf '%s\n' "$list" | wc -l)" -gt 1 ]; then
    title=$(osascript -e 'tell application "Vivaldi" to get title of active tab of window 1')
    id=$(printf '%s\n' "$list" | awk -F'|' -v t="$title - Vivaldi" '$2 == t { print $1; exit }')
    if [ -n "$id" ]; then
      echo "$id"
      return 0
    fi
  fi
  printf '%s\n' "$list" | head -n 1 | cut -d'|' -f1
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

# drv_space_window <name> <index>: show the workspace in a new window. A
# workspace can be open in only one window. If it is already open in a
# window, Vivaldi focuses that window instead, and the new window stays
# empty. Then close the new window: this driver made it, and it is empty.
drv_space_window() {
  local pos before new focused
  pos=$(viv_position "$1")
  if [ "$pos" -eq 0 ]; then
    echo "Vivaldi has no workspace $1" >&2
    return 1
  fi
  before=$(aero_ids | tr '\n' ' ')
  osascript -e 'tell application "Vivaldi" to make new window' > /dev/null || return 1
  new=$(aero_wait_new "$before") || return 1
  aero_focus "$new" || return 1
  viv_key "$pos" || return 1
  sleep 0.4
  focused=$("$AEROSPACE_BIN" list-windows --focused --format '%{window-id}')
  if [ "$focused" != "$new" ]; then
    "$AEROSPACE_BIN" close --window-id "$new"
    aero_focus "$focused"
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

# drv_focus_tab <window id> <tab id>
drv_focus_tab() {
  local pos
  pos=$(viv_js tab-position "$2") || return 1
  viv_focus_tab "$2" "$pos"
}
