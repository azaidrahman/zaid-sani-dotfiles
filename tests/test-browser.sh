#!/usr/bin/env bash
# Tests for the browser command (dot_local/bin/executable_browser) and the
# Vivaldi driver (dot_config/browser/drivers/vivaldi.sh and vivaldi.js).
#
# The tests use a fake driver, the real Vivaldi driver, and stubs for
# terminal-notifier, osascript, aerospace, and pgrep. They do not change
# windows, browsers, or system settings.
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
drv_current_space() { echo Work; }
drv_open_in() { echo "open-in $*" >> "$STUB_LOG"; }
EOF

# The real Vivaldi and Arc drivers, with Vivaldi settings that have two
# workspaces, and a stub for the Arc script that floats a window.
cp "$repo_root/dot_config/browser/drivers/vivaldi.sh" "$repo_root/dot_config/browser/drivers/vivaldi.js" \
  "$repo_root/dot_config/browser/drivers/arc.sh" "$home/drivers/"
echo '{"vivaldi":{"workspaces":{"list":[{"id":1,"name":"Work"},{"id":2,"name":"Zaid"}],"link_routes":[]}}}' > "$TMP/viv-prefs.json"

cat > "$TMP/bin/notifier" <<'EOF'
#!/bin/sh
echo "notify $*" >> "$STUB_LOG"
EOF
# osascript: the bookmark script only reads a file, so it runs for real.
# "make new window" adds window 20 to the AeroSpace windows, and returns the
# Vivaldi id 777. "vivaldi.js windows" returns $STUB_VIV, and
# "vivaldi.js window-title" returns $STUB_WTITLE. Key codes and window
# closes go to the log.
cat > "$TMP/bin/osascript" <<'EOF'
#!/bin/sh
case "$*" in
  *bookmarks.js*) exec /usr/bin/osascript "$@" ;;
  *"make new window"*) echo 20 >> "$STUB_DIR/windows"; echo 777; exit 0 ;;
  *vivaldi.js*windows) printf '%s\n' "$STUB_VIV"; exit 0 ;;
  *vivaldi.js*window-empty*) echo "$STUB_EMPTY"; exit 0 ;;
  *vivaldi.js*window-title*) echo "$STUB_WTITLE"; exit 0 ;;
esac
if [ "${1:-}" = - ]; then
  body=$(cat)
  case "$body" in
    *"key code"*) echo "key $2" >> "$STUB_LOG"; exit 0 ;;
    *close*) echo "close $2" >> "$STUB_LOG"; exit 0 ;;
  esac
fi
echo "osascript $*" >> "$STUB_LOG"
EOF
# aerospace: the window ids are in $STUB_DIR/windows, the titles in
# $STUB_TITLES, and the focused window in $STUB_FOCUSED. Each line of
# $STUB_TITLES is "<id>|<workspace is focused>|<workspace is visible>|<title>".
# Other calls go to the log.
cat > "$TMP/bin/aerospace" <<'EOF'
#!/bin/sh
case "$1" in
  list-windows)
    case "$*" in
      *--focused*) echo "$STUB_FOCUSED" ;;
      *window-title*) printf '%s\n' "$STUB_TITLES" ;;
      *) cat "$STUB_DIR/windows" ;;
    esac ;;
  *) echo "aerospace $*" >> "$STUB_LOG" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/pgrep"
# open: never open a real URL or application.
cat > "$TMP/bin/open" <<'EOF'
#!/bin/sh
echo "open $*" >> "$STUB_LOG"
EOF
mkdir -p "$TMP/home/.config/karabiner/scripts"
cat > "$TMP/home/.config/karabiner/scripts/arc-float-tab.sh" <<'EOF'
#!/bin/sh
echo "float-tab $*" >> "$STUB_LOG"
EOF
chmod +x "$TMP/bin/notifier" "$TMP/bin/osascript" "$TMP/bin/aerospace" "$TMP/bin/pgrep" \
  "$TMP/bin/open" "$TMP/home/.config/karabiner/scripts/arc-float-tab.sh"

# run <label> <status> <expect> <forbid> <state> <args...>
#   status  the expected exit status
#   expect  texts that the result must contain, separated by ";;"
#   forbid  a text that the result must not contain, or "-"
#   state   the content of the state file before the run, or "-" for none
# The result is the stdout, the log of the stubs, and the state file after
# the run: "out=<stdout> log=<log> state=<state>". For the Vivaldi driver,
# set BROWSER_DRIVER=vivaldi and the STUB_* values of the stubs above. The
# AeroSpace windows start as the one window 10.
run() {
  local label=$1 want_status=$2 expect=$3 forbid=$4 before=$5 out status actual part ok=1
  shift 5
  : > "$TMP/log"
  echo 10 > "$TMP/windows"
  rm -f "$state/current"
  [ "$before" = - ] || printf '%s\n' "$before" > "$state/current"
  out=$(env -i HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" \
    BROWSER_HOME="$home" BROWSER_NOTIFIER="$TMP/bin/notifier" \
    XDG_STATE_HOME="$TMP/state" STUB_LOG="$TMP/log" STUB_DIR="$TMP" \
    AEROSPACE_BIN="$TMP/bin/aerospace" VIVALDI_PREFS="$TMP/viv-prefs.json" \
    BROWSER_DRIVER="${BROWSER_DRIVER:-}" BROWSER_WAIT_TRIES=2 \
    STUB_FOCUSED="${STUB_FOCUSED:-}" STUB_TITLES="${STUB_TITLES:-}" \
    STUB_VIV="${STUB_VIV:-}" STUB_EMPTY="${STUB_EMPTY:-}" STUB_WTITLE="${STUB_WTITLE:-}" \
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
run "driver override" 0 "log=tab gmail Work https://example.com/u/1" notify - tab gmail
run "unknown tab" 2 "unknown tab nope" "log=tab" - tab nope
run "use" 0 "state=fake;;osascript -l JavaScript $home/lib/set-default.js com.example.fake" notify gone use fake
run "tabs not supported" 0 'fake cannot list tabs;;"valid":false' notify - tabs
run "bookmarks of all spaces" 0 'Work board;;Home recipes;;"arg":"https://example.com/board";;"variables":{"space":"Zaid"}' "Untagged page" - bookmarks
run "open a URL in a space" 0 "log=open-in Zaid 3 https://example.com/recipes" notify - open-in Zaid https://example.com/recipes
run "open --float: a driver that cannot float opens the URL" 0 "log=open -b com.example.fake https://example.com/todo" notify - \
  open --float https://example.com/todo https://example.com/todo
BROWSER_DRIVER=arc run "open --float: Arc opens the URL in a floating window" 0 "log=float-tab https://example.com/todo" notify - \
  open --float https://example.com/todo https://example.com/todo

# The Vivaldi driver. Zaid is the second workspace, so its key is ⌃⇧3
# (key code 20). Window 10 is the main window, and window 20 is the new
# window. STUB_FOCUSED is the window that has the focus after the key.
# STUB_VIV gives the Vivaldi windows from front to back, one line for each
# window: the mode, a tab, the position of the workspace that the window
# shows, a tab, and the title of the active tab.
BROWSER_DRIVER=vivaldi STUB_FOCUSED=10 STUB_TITLES='10|false|false|Mail - Vivaldi' STUB_EMPTY=no \
  run "own window: keep the new window when it has tabs" 0 "key 20" close - space-window Zaid
BROWSER_DRIVER=vivaldi STUB_FOCUSED=10 STUB_TITLES='10|false|false|Mail - Vivaldi' STUB_EMPTY=yes \
  run "own window: close the new window when Vivaldi focused a different window" 0 \
  "key 20;;close 777" - - space-window Zaid
BROWSER_DRIVER=vivaldi STUB_FOCUSED=20 STUB_TITLES='10|false|false|Mail - Vivaldi' STUB_EMPTY=yes \
  run "own window: keep the new window when it shows an empty workspace" 0 "key 20" close - \
  space-window Zaid
BROWSER_DRIVER=vivaldi STUB_TITLES='10|false|false|Mail - Vivaldi' STUB_VIV=$'normal\t1\tMail' \
  run "no space: ⌃⇧1 (key code 18) shows the tabs in no workspace" 0 \
  "aerospace focus --window-id 10;;key 18" - - no-space
BROWSER_DRIVER=vivaldi STUB_TITLES=$'11|false|false|Other - Vivaldi\n10|false|false|Inbox | Gmail - Vivaldi' \
  STUB_VIV=$'normal\t2\tInbox | Gmail\nnormal\t2\tOther' \
  run "front window: a title with |" 0 "aerospace focus --window-id 10" "window-id 11" - space Work
BROWSER_DRIVER=vivaldi STUB_TITLES='10|false|false|Private - Vivaldi' STUB_VIV=$'incognito\t1\tPrivate' \
  run "front window: open a window when all windows are private" 0 \
  "aerospace focus --window-id 20;;key 19" "window-id 10" - space Work
# The start page has no title for scripting, but AeroSpace shows
# "Start Page". The private window 15 is first in the AeroSpace list.
BROWSER_DRIVER=vivaldi \
  STUB_TITLES=$'15|false|false|Bank - Vivaldi\n10|false|false|Start Page - Vivaldi\n11|false|false|Video - Vivaldi' \
  STUB_VIV=$'normal\t1\t\nincognito\t1\tBank\nnormal\t1\tVideo' \
  run "front window: the title of the active tab differs from the window title" 0 \
  "aerospace focus --window-id 10;;key 18" "window-id 15" - no-space
# If the driver focuses a window on a hidden AeroSpace workspace, AeroSpace
# shows that workspace on its monitor. If the driver focuses a window that
# does not show the workspace, the window covers the other windows of its
# AeroSpace workspace. Never use the private window 15.
# Window 10 is on the focused AeroSpace workspace. The private window 15 and
# windows 11 and 12 show Zaid. Window 12 is in front of window 11, but it is
# on a hidden workspace.
BROWSER_DRIVER=vivaldi \
  STUB_TITLES=$'10|true|true|Mail - Vivaldi\n15|true|true|Bank - Vivaldi\n11|false|true|Video - Vivaldi\n12|false|false|News - Vivaldi' \
  STUB_VIV=$'normal\t1\tMail\nincognito\t2\tBank\nnormal\t2\tNews\nnormal\t2\tVideo' \
  run "front window: prefer a visible window that shows the workspace" 0 \
  "aerospace focus --window-id 11;;key 20" "window-id 15" - space Zaid
# No window shows Zaid. Window 10 is the front window, but its AeroSpace
# workspace is hidden.
BROWSER_DRIVER=vivaldi \
  STUB_TITLES=$'10|false|false|Mail - Vivaldi\n15|true|true|Bank - Vivaldi\n11|false|true|Video - Vivaldi\n12|true|true|News - Vivaldi' \
  STUB_VIV=$'normal\t1\tMail\nincognito\t1\tBank\nnormal\t1\tVideo\nnormal\t1\tNews' \
  run "front window: else prefer a window on the focused workspace" 0 \
  "aerospace focus --window-id 12;;key 20" "window-id 15" - space Zaid
BROWSER_DRIVER=vivaldi \
  STUB_TITLES=$'10|false|false|Mail - Vivaldi\n15|true|true|Bank - Vivaldi\n11|false|true|Video - Vivaldi' \
  STUB_VIV=$'normal\t1\tMail\nincognito\t1\tBank\nnormal\t1\tVideo' \
  run "front window: else prefer a window on a visible workspace" 0 \
  "aerospace focus --window-id 11;;key 20" "window-id 15" - space Zaid
# focus-tab with a position: focus the window of the tab, which is window 11
# with the title "Video", and show the workspace in it. No other window
# shows Zaid, and window 10 is on the focused workspace. The tab "-" only
# shows the workspace.
BROWSER_DRIVER=vivaldi STUB_WTITLE=Video \
  STUB_TITLES=$'10|true|true|Mail - Vivaldi\n11|false|false|Video - Vivaldi' \
  run "focus tab: use the window of the tab" 0 \
  "aerospace focus --window-id 11;;key 20;;activate 42" "window-id 10" - focus-tab 5 42 2
BROWSER_DRIVER=vivaldi STUB_WTITLE=Video \
  STUB_TITLES=$'10|true|true|Mail - Vivaldi\n11|false|false|Video - Vivaldi' \
  run "focus tab: the tab - only shows the workspace" 0 \
  "aerospace focus --window-id 11;;key 19" "activate" - focus-tab 5 - 1

# The URL matching of vivaldi.js, run for real. js_check loads vivaldi.js
# from this repository with eval, to call its functions. It reads no other
# input. osascript calls "run" at the end, so "run" returns the expression
# instead of the run function of vivaldi.js.
js_check() {
  local label=$1 want=$2 expr=$3 got
  got=$(/usr/bin/osascript -l JavaScript -e "ObjC.import('Foundation');
    eval(\$.NSString.stringWithContentsOfFileEncodingError('$repo_root/dot_config/browser/drivers/vivaldi.js', \$.NSUTF8StringEncoding, null).js);
    run = () => $expr;" 2>&1)
  if [ "$got" = "$want" ]; then printf 'ok   - %s\n' "$label"
  else printf 'FAIL - %s\n      want: %s\n      got:  %s\n' "$label" "$want" "$got"; fail=1; fi
}
js_check "a prefix matches only at a URL boundary, and an exact URL wins" \
  "false,true,false,true,https://x/a" \
  "[urlStartsWith('https://x/ws/api-gateway', 'https://x/ws/api'),
    urlStartsWith('https://x/ws/api/src', 'https://x/ws/api'),
    urlStartsWith('https://x/pr/123', 'https://x/pr/12'),
    urlStartsWith('https://x/pr/12?tab=diff', 'https://x/pr/12'),
    firstMatch([{url: 'https://x/a/b'}, {url: 'https://x/a'}], 'https://x/a', (u) => u).url].join()"

# watchStep, one row for each case. Workspace 1 is Work, and 2 is Zaid. A
# rule sends https://r/ to Zaid. Tab "a" is in Work, and tab "z" is in Zaid.
# Each row starts with a first look at "a" and "z" in one window, which
# shows Work. Then the row gives the looks after it, 1 second apart. "sim"
# prints each note as "<pos>", or "<pos>><back>" for a jump, or "-" for no
# note.
js_check "watch: go back after a jump, and notify for a tab that the user cannot see" \
  "2|2>1|-|1|-|2|-|2>1|-|2" \
  "(() => {
    const load = () => ({
      ws: { list: [{ id: 1, name: 'Work' }, { id: 2, name: 'Zaid' }],
        rules: [{ type: 'STARTSWITH', expression: 'https://r/', workspaceId: 2 }] },
      session: new Map([['a', 1], ['z', 2]]) });
    const snap = (front, activeId, tabs, mode = 'normal') => ({ front, windows: [{ id: '9', mode, activeId,
      tabs: tabs.map(([id, url]) => ({ id, url })) }] });
    const A = ['a', 'https://x/a'];
    const Z = ['z', 'https://x/z'];
    const R = ['r', 'https://r/1'];
    const sim = (...looks) => {
      let state = watchStep(null, snap(true, 'a', [A, Z]), load, 0).state;
      const out = [];
      looks.forEach((s, i) => {
        const r = watchStep(state, s, load, i + 1);
        state = r.state;
        r.notes.forEach((n) => out.push(n.back === undefined ? n.pos : n.pos + '>' + n.back));
      });
      return out.join() || '-';
    };
    const many = [1, 2, 3, 4, 5, 6].map((n) => ['m' + n, 'https://r/' + n]);
    return [
      // A rule moved a background tab to Zaid, and Vivaldi still shows Work.
      sim(snap(true, 'a', [A, Z, R]), snap(true, 'a', [A, Z, R])),
      // A rule moved the new active tab to Zaid: Vivaldi jumped.
      sim(snap(true, 'r', [A, Z, R]), snap(true, 'r', [A, Z, R])),
      // A background tab with no rule stays in Work, which the user sees.
      sim(snap(true, 'a', [A, Z, ['n', 'https://x/n']]), snap(true, 'a', [A, Z, ['n', 'https://x/n']])),
      // The same tab, while another application is frontmost.
      sim(snap(false, 'a', [A, Z, ['n', 'https://x/n']]), snap(false, 'a', [A, Z, ['n', 'https://x/n']])),
      // More than WATCH_BURST new tabs: a restored session.
      sim(snap(true, 'a', [A, Z, ...many]), snap(true, 'a', [A, Z, ...many])),
      // A blank tab that gets a URL later. The wait starts at the URL.
      sim(snap(true, 'a', [A, Z, ['b', 'about:blank']]), snap(true, 'a', [A, Z, ['b', 'https://r/2']]),
        snap(true, 'a', [A, Z, ['b', 'https://r/2']])),
      // A private window has no workspaces.
      sim(snap(false, 'a', [A, Z, R], 'incognito'), snap(false, 'a', [A, Z, R], 'incognito')),
      // The user typed a URL of the rule in the active tab: Vivaldi jumped.
      sim(snap(true, 'a', [['a', 'https://r/1'], Z])),
      // The user went to Zaid: the tab is not new, and its URL is the same.
      sim(snap(true, 'z', [A, Z])),
      // A jump while another application is frontmost: no keys, only a note.
      sim(snap(false, 'r', [A, Z, R]), snap(false, 'r', [A, Z, R])),
    ].join('|');
  })()"

exit "$fail"
