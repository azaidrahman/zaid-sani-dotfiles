#!/usr/bin/env bash
# Tests for the browser command (dot_local/bin/executable_browser).
#
# The tests use a fake driver, and stubs for terminal-notifier and
# osascript. They do not change windows, browsers, or system settings.
# Each case runs the command with /bin/bash (bash 3.2) and an empty
# environment, as Karabiner does.
#
# Run with: bash tests/test-browser.sh
set -u
repo_root=$(cd "$(dirname "$0")/.." && pwd)
BROWSER="$repo_root/dot_local/bin/executable_browser"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

home="$TMP/browser" # BROWSER_HOME
state="$TMP/state/browser"
mkdir -p "$home/drivers" "$TMP/bin" "$state"
if [ -d "$repo_root/dot_config/browser/lib" ]; then
  cp -R "$repo_root/dot_config/browser/lib" "$home/lib"
fi

cat > "$home/config.sh" <<EOF
BROWSER_DEFAULT=fake
BROWSER_SPACES="Work Research Zaid YouTube Fail"
BROWSER_TABS='gchat|Work|https://chat.google.com
gmail|Work|https://mail.google.com/mail/u/0
gmail@fake|Work|https://example.com/u/1'
BROWSER_BOOKMARK_TAGS='Work|browser/work
Zaid|browser/personal'
BROWSER_BOOKMARKS="$TMP/pinplus.json"
EOF

# A bookmark cache in the shape of the Pin Plus Alfred workflow: the tags of
# a bookmark are the subtitle of its "alt" modifier.
cat > "$TMP/pinplus.json" <<'EOF'
[{"title": "Work board", "arg": "https://example.com/board", "mods": {"alt": {"subtitle": "browser/work tools"}}},
 {"title": "Home recipes", "arg": "https://example.com/recipes", "mods": {"alt": {"subtitle": "cooking browser/personal"}}},
 {"title": "Untagged page", "arg": "https://example.com/other", "mods": {"alt": {"subtitle": "[No tags]"}}}]
EOF

cat > "$home/drivers/fake.sh" <<'EOF'
DRIVER_APP=Fake
DRIVER_BUNDLE=com.example.fake
drv_space() {
  if [ "$1" = Fail ]; then echo boom >&2; return 1; fi
  echo "space $*" >> "$STUB_LOG"
}
drv_tab() { echo "tab $*" >> "$STUB_LOG"; }
drv_space_window() { echo "space-window $*" >> "$STUB_LOG"; }
drv_current_space() { echo Work; }
drv_open_in() { echo "open-in $*" >> "$STUB_LOG"; }
EOF

cat > "$TMP/bin/notifier" <<'EOF'
#!/bin/sh
echo "notify $*" >> "$STUB_LOG"
EOF
# The bookmark script only reads a file, so it runs for real.
cat > "$TMP/bin/osascript" <<'EOF'
#!/bin/sh
case "$*" in *bookmarks.js*) exec /usr/bin/osascript "$@" ;; esac
echo "osascript $*" >> "$STUB_LOG"
EOF
chmod +x "$TMP/bin/notifier" "$TMP/bin/osascript"

# run <label> <status> <expect> <forbid> <state> <args...>
#   status  the expected exit status
#   expect  texts that the result must contain, separated by ";;"
#   forbid  a text that the result must not contain, or "-"
#   state   the content of the state file before the run, or "-" for none
# The result is the stdout, the log of the stubs, and the state file after
# the run: "out=<stdout> log=<log> state=<state>".
run() {
  local label=$1 want_status=$2 expect=$3 forbid=$4 before=$5 out status actual part ok=1
  shift 5
  : > "$TMP/log"
  rm -f "$state/current"
  [ "$before" = - ] || printf '%s\n' "$before" > "$state/current"
  out=$(env -i HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" \
    BROWSER_HOME="$home" BROWSER_NOTIFIER="$TMP/bin/notifier" \
    XDG_STATE_HOME="$TMP/state" STUB_LOG="$TMP/log" \
    /bin/bash "$BROWSER" "$@" 2>/dev/null)
  status=$?
  actual="out=$out log=$(tr '\n' ' ' < "$TMP/log")state=$(cat "$state/current" 2>/dev/null)"
  [ "$status" = "$want_status" ] || ok=0
  while [ -n "$expect" ]; do
    part=${expect%%;;*}
    case "$actual" in *"$part"*) ;; *) ok=0 ;; esac
    [ "$part" = "$expect" ] && expect="" || expect=${expect#*;;}
  done
  if [ "$forbid" != - ]; then
    case "$actual" in *"$forbid"*) ok=0 ;; esac
  fi
  if [ "$ok" = 1 ]; then printf 'ok   - %s\n' "$label"
  else printf 'FAIL - %s\n      exit %s (want %s): %s\n' "$label" "$status" "$want_status" "$actual"; fail=1; fi
}

# The dispatcher.
run "unsupported action" 2 "notify -title browser -message fake cannot focus-tab" - - focus-tab 1 2
run "failed action" 1 "fake space failed: boom" - - space Fail
run "unknown driver" 2 "unknown driver gone" "log=space" gone space Work
run "space index" 0 "log=space YouTube 4" notify - space YouTube
run "unknown space" 2 "unknown space Nope" "log=space" - space Nope
run "space in its own window" 0 "log=space-window Zaid 3" notify - space-window Zaid
run "driver override" 0 "log=tab gmail Work https://example.com/u/1" notify - tab gmail
run "unknown tab" 2 "unknown tab nope" "log=tab" - tab nope
run "use" 0 "state=fake;;osascript -l JavaScript $home/lib/set-default.js com.example.fake" notify gone use fake
run "tabs not supported" 0 'fake cannot list tabs;;"valid":false' notify - tabs
run "bookmarks of all spaces" 0 'Work board;;Home recipes;;"arg":"https://example.com/board";;"variables":{"space":"Zaid"}' "Untagged page" - bookmarks
run "open a URL in a space" 0 "log=open-in Zaid 3 https://example.com/recipes" notify - open-in Zaid https://example.com/recipes

exit "$fail"
