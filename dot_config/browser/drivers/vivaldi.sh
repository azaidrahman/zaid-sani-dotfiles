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

# viv_main_window [<position>]: print the AeroSpace id of the main Vivaldi
# window. This is a window that is not private (see check 7). If you give a
# position, use a window that shows the workspace at the position first.
# Then use a window on the focused AeroSpace workspace, then a window on a
# visible workspace, then the front window.
# When AeroSpace focuses a window, it brings the window to the front of its
# AeroSpace workspace, and it shows that workspace on its monitor. Thus focus
# only the window that the user wants to see. If the driver focuses a
# different window and sends the key, Vivaldi then goes to the window that
# shows the workspace, but the first window still covers the other windows.
# If Vivaldi has no window, or has only private windows, open a window.
viv_main_window() {
  local target=${1:-} list wins id before
  list=$("$AEROSPACE_BIN" list-windows --monitor all --app-bundle-id "$DRIVER_BUNDLE" \
    --format '%{window-id}|%{workspace-is-focused}|%{workspace-is-visible}|%{window-title}' |
    grep -v '|Picture in Picture$')
  if [ -z "$list" ]; then
    before=$(aero_ids | tr '\n' ' ')
    open -b "$DRIVER_BUNDLE" || return 1
    aero_wait_new "$before"
    return
  fi
  # One line for each Vivaldi window, from front to back: the mode, the
  # position of the workspace that it shows, and the title of the active tab.
  if ! wins=$(viv_js windows); then
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
  # its title. Never use a window that pairs with a private window. Give each
  # other window a rank, and use the window with the lowest rank:
  # - First a window that shows the target workspace. A window that has no
  #   pair does not count: its workspace is not known.
  # - Then the place: 0 on the focused workspace, 1 on a visible workspace,
  #   2 on a hidden workspace.
  # - In one place: the pair of the front normal window first. Then a window
  #   that has no pair: it can be the front window (see check 8). Then the
  #   other normal windows, from front to back.
  # The first three fields of an AeroSpace line have no "|". The rest is the
  # title, which can contain "|".
  id=$({
    printf '%s\n' "$wins" | sed 's/^/V/'
    printf '%s\n' "$list" | sed 's/^/A/'
  } | awk -v target="$target" '
    /^V/ {
      rest = substr($0, 2)
      t = index(rest, "\t"); if (!t) next
      n++; mode[n] = substr(rest, 1, t - 1); rest = substr(rest, t + 1)
      t = index(rest, "\t"); if (!t) { n--; next }
      pos[n] = substr(rest, 1, t - 1); want[n] = substr(rest, t + 1) " - Vivaldi"
      next
    }
    /^A/ {
      rest = substr($0, 2); m++
      for (f = 1; f <= 3; f++) {
        i = index(rest, "|"); if (!i) { m--; next }
        field[f] = substr(rest, 1, i - 1); rest = substr(rest, i + 1)
      }
      wid[m] = field[1]; title[m] = rest
      place[m] = field[2] == "true" ? 0 : field[3] == "true" ? 1 : 2
    }
    END {
      for (v = 1; v <= n; v++) {
        if (!main && mode[v] == "normal") main = v
        for (a = 1; a <= m; a++)
          if (!owner[a] && title[a] == want[v]) { owner[a] = v; break }
      }
      best = ""
      for (a = 1; a <= m; a++) {
        if (owner[a] && mode[owner[a]] != "normal") continue
        order = owner[a] == main && main ? 0 : !owner[a] ? 1 : 1 + owner[a]
        shows = target != "" && owner[a] && pos[owner[a]] == target
        rank = (shows ? 0 : 10000) + place[a] * 1000 + order
        if (best == "" || rank < best) { best = rank; id = wid[a] }
      }
      if (best != "") print id
    }')
  if [ -z "$id" ]; then
    echo "cannot find the main Vivaldi window" >&2
    return 1
  fi
  echo "$id"
}

# viv_focus_main [<position>]: focus the main Vivaldi window (see
# viv_main_window).
viv_focus_main() {
  local window
  window=$(viv_main_window "${1:-}") || return 1
  aero_focus "$window"
}

# viv_show <position>: focus the main window for the workspace at the
# position, and show that workspace (1 is the first workspace).
viv_show() {
  viv_focus_main "$1" || return 1
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

# viv_window_aero <Vivaldi window id>: print the AeroSpace id of the Vivaldi
# window, or nothing. Pair the windows by the title of the active tab. If two
# AeroSpace windows have that title, print nothing: the pair is not sure.
viv_window_aero() {
  local title
  title=$(viv_js window-title "$1") || return 0
  [ -n "$title" ] || return 0
  "$AEROSPACE_BIN" list-windows --monitor all --app-bundle-id "$DRIVER_BUNDLE" \
    --format '%{window-id}|%{workspace-is-focused}|%{workspace-is-visible}|%{window-title}' |
    awk -v want="$title - Vivaldi" '
      {
        rest = $0
        for (f = 1; f <= 3; f++) {
          i = index(rest, "|"); if (!i) next
          if (f == 1) wid = substr(rest, 1, i - 1)
          rest = substr(rest, i + 1)
        }
        if (rest == want) { n++; id = wid }
      }
      END { if (n == 1) print id }'
}

# drv_focus_tab <window id> <tab id> [<position>]: focus the tab. The
# position is of the workspace of the tab. Without it, vivaldi.js finds it
# (see tab-position). With the tab id "-", only show the workspace.
# Focus the window of the tab, and show the workspace in it. If AeroSpace
# does not have that window, use the main window for the workspace.
drv_focus_tab() {
  local pos=${3:-} aero
  if [ -z "$pos" ]; then
    [ "$2" != - ] || return 1
    pos=$(viv_js tab-position "$2") || return 1
  fi
  aero=$(viv_window_aero "$1")
  if [ -n "$aero" ]; then
    aero_focus "$aero" || return 1
    if [ "$pos" -gt 0 ] || [ -n "${3:-}" ]; then
      viv_key "$pos" || return 1
    fi
  elif [ "$2" = - ]; then
    viv_show "$pos" || return 1
  else
    viv_focus_tab "$2" "$pos" || return 1
    return 0
  fi
  [ "$2" = - ] || viv_js activate "$2" > /dev/null
}
