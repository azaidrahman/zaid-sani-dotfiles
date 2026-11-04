# shellcheck shell=bash disable=SC2034 # The browser command uses DRIVER_*.
# The driver for Arc. The browser command sources this file.
#
# The driver calls the Arc scripts in ~/.config/karabiner/scripts. Do not move
# or change them while Arc is in use: the Alfred workflow "Arc Tabs and
# Spaces" also calls them by their full paths. When Arc is retired, move this
# driver, the arc-*.sh scripts, and their test to archive/.
#
# Arc finds tabs by their custom titles, not by URL. Thus this driver has no
# drv_focus_url, and "browser open" always opens a new tab in Arc.

DRIVER_APP=Arc
DRIVER_BUNDLE=company.thebrowser.Browser

arc_scripts="$HOME/.config/karabiner/scripts"

# The Arc spaces. The browser configuration can have more spaces than Arc.
arc_spaces=" Work Research Zaid "

# arc_title <name>: print the Arc title of a named tab.
arc_title() {
  case "$1" in
    gchat) echo GCHAT ;;
    gmail) echo "GMAIL GMD" ;;
    *)
      echo "Arc has no tab for $1" >&2
      return 1
      ;;
  esac
}

# drv_space <name> <index>
drv_space() {
  case "$arc_spaces" in
    *" $1 "*) ;;
    *)
      echo "Arc has no space $1" >&2
      return 1
      ;;
  esac
  "$arc_scripts/arc-space.sh" "$1"
}

# drv_tab <name> <space> <url prefix>
drv_tab() {
  local title
  title=$(arc_title "$1") || return 1
  "$arc_scripts/arc-tab.sh" "$2" "$title"
}
