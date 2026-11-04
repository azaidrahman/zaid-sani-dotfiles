# Shared AeroSpace functions for the browser drivers.
#
# The browser command sources this file before it sources the driver. The
# functions use DRIVER_APP, DRIVER_BUNDLE, and AEROSPACE_BIN. They work with
# bash 3.2.
#
# Do not make a browser active with AppleScript ("activate" or "set
# frontmost"). macOS then brings all windows of the browser to the front. In
# an AeroSpace accordion workspace, they then cover the other windows. Focus
# one window with aero_focus.

# aero_ids: print the AeroSpace ids of the browser windows, one on each line.
aero_ids() {
  "$AEROSPACE_BIN" list-windows --monitor all --app-bundle-id "$DRIVER_BUNDLE" \
    --format '%{window-id}'
}

# aero_focus <window id>
aero_focus() {
  "$AEROSPACE_BIN" focus --window-id "$1"
}

# aero_wait_new <ids before>: wait until AeroSpace lists a browser window that
# is not in the space-separated list, and print its id. A browser does not
# report a new window to AeroSpace at once. Stop after BROWSER_WAIT_TRIES
# tries (default 50), with 0.1 seconds between them.
aero_wait_new() {
  local before=" $1 " tries=${BROWSER_WAIT_TRIES:-50} i=0 id
  while [ "$i" -lt "$tries" ]; do
    for id in $(aero_ids); do
      case "$before" in
        *" $id "*) ;;
        *)
          echo "$id"
          return 0
          ;;
      esac
    done
    sleep 0.1
    i=$((i + 1))
  done
  echo "the new $DRIVER_APP window did not come" >&2
  return 1
}
