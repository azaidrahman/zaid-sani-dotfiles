#!/usr/bin/env bash
# Tests for winpeek (dot_local/bin/executable_winpeek).
#
# The tests use stubs for aerospace, screencapture, osascript, and magick.
# They do not focus windows, take screenshots, or read app icons.
#
# Run with: bash tests/test-winpeek.sh
set -u
repo_root=$(cd "$(dirname "$0")/.." && pwd)
WINPEEK="$repo_root/dot_local/bin/executable_winpeek"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

mkdir -p "$TMP/bin"
export WINPEEK_CACHE="$TMP/cache"
export PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# The stub of aerospace prints $TMP/windows.json, or fails if the file is
# missing. $TMP/focused holds "<window id> <pid>" of the focused window. The
# stub logs each focus.
cat > "$TMP/bin/aerospace" <<EOF
#!/bin/bash
case "\$*" in
  *--all*) cat "$TMP/windows.json" 2>/dev/null || exit 1 ;;
  *--focused*app-pid*) cat "$TMP/focused" 2>/dev/null ;;
  *--focused*) cut -d' ' -f1 "$TMP/focused" 2>/dev/null ;;
  focus*) echo "\$*" >> "$TMP/focus.log" ;;
esac
EOF
# The stub of screencapture writes the window ID to the file. It fails for
# the IDs in $TMP/fail.
cat > "$TMP/bin/screencapture" <<EOF
#!/bin/bash
id=\${@: -2:1}; out=\${@: -1}
grep -qx "\$id" "$TMP/fail" 2>/dev/null && exit 1
echo "\$id" > "\$out"
EOF
# The stub of osascript has three modes. With no arguments after the JXA
# script, it prints $TMP/cg.json (the window list of macOS). With arguments,
# it writes an icon "<dir>/<pid>.png" for each pid and logs the pids. Other
# calls go to a log.
cat > "$TMP/bin/osascript" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-l" ]; then
  [ \$# -le 3 ] && { cat "$TMP/cg.json" 2>/dev/null; exit 0; }
  shift 3; dir=\$1; shift
  for pid in "\$@"; do echo "icon \$pid" > "\$dir/\$pid.png"; echo "\$pid" >> "$TMP/icons.log"; done
  exit 0
fi
echo "\$*" >> "$TMP/osascript.log"
EOF
# The stub of magick adds the text of the icon (the argument after "(") to
# the text of the screenshot (the first argument). The output is the last
# argument.
cat > "$TMP/bin/magick" <<'EOF'
#!/bin/bash
shot=$1
while [ "$1" != "(" ]; do shift; done
{ cat "$shot"; cat "$2"; } > "${@: -1}"
EOF
chmod +x "$TMP/bin/"*

# The macOS window list. It repeats AeroSpace window 30 and has a Wine window
# (77), a helper window with no title (78), and a small window (79).
cat > "$TMP/cg.json" <<'EOF'
[{"id":30,"pid":3,"owner":"Vivaldi","title":"Docs","w":800,"h":600},
 {"id":77,"pid":500,"owner":"Game.exe","title":"Game","w":960,"h":572},
 {"id":78,"pid":501,"owner":"Helper","title":"","w":800,"h":600},
 {"id":79,"pid":502,"owner":"Tiny","title":"Tip","w":50,"h":20}]
EOF

check() { # name expected actual
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; fail=1
  fi
}

win() { # id workspace pid app title [bundle id]
  printf '{"window-id":%s,"workspace":"%s","app-pid":%s,"app-name":"%s","app-bundle-id":"%s","app-bundle-path":"/Applications/%s.app","window-title":"%s"}' \
    "$1" "$2" "$3" "$4" "${6:-com.test.$4}" "$4" "$5"
}

echo "[$(win 30 web 3 Vivaldi Docs),$(win 10 2 1 Slack ''),$(win 20 10 2 Rex shell),$(win 40 1 4 Mail Inbox)]" \
  > "$TMP/windows.json"
echo "40 4 com.test.Mail" > "$TMP/focused"

# A capture writes one screenshot for each window, with the app icon on it.
"$WINPEEK" capture
check "capture writes one file for each window, Wine window too" 5 "$(ls "$WINPEEK_CACHE"/*.jpg | wc -l | tr -d ' ')"
check "capture adds the app icon to the screenshot" "77 icon 500" "$(cat "$WINPEEK_CACHE"/77.*.jpg | tr '\n' ' ' | sed 's/ $//')"

# A second capture adds a new screenshot. It removes an old screenshot after
# one minute, and keeps the old one of a window that it cannot capture. It
# removes the screenshot of a closed window and the icon of an app that quit.
# It does not read the icons again.
old10=$(ls "$WINPEEK_CACHE"/10.*.jpg)
old20=$(ls "$WINPEEK_CACHE"/20.*.jpg)
touch -t "$(date -v-2M +%Y%m%d%H%M.%S)" "$old10"
echo 20 > "$TMP/fail"
: > "$TMP/icons.log"
echo "[$(win 30 web 3 Vivaldi Docs),$(win 10 2 1 Slack ''),$(win 20 10 2 Rex shell)]" > "$TMP/windows.json"
"$WINPEEK" capture
new10=$(ls "$WINPEEK_CACHE"/10.*.jpg)
check "capture removes a screenshot after one minute, not before" "1 yes 2" \
  "$(ls "$WINPEEK_CACHE"/10.*.jpg | wc -l | tr -d ' ') $([ "$new10" != "$old10" ] && echo yes) $(ls "$WINPEEK_CACHE"/30.*.jpg | wc -l | tr -d ' ')"
check "a failed capture keeps the old screenshot" "$old20" "$(ls "$WINPEEK_CACHE"/20.*.jpg)"
check "capture removes the screenshot of a closed window" "" "$(ls "$WINPEEK_CACHE"/40.*.jpg 2>/dev/null)"
check "capture reads only new icons, and removes the icon of an app that quit" " 1 2 3 500" \
  "$(cat "$TMP/icons.log") $(cd "$WINPEEK_CACHE/icons" && ls | sed 's/.png//' | sort -n | tr '\n' ' ' | sed 's/ $//')"

# The list, after a recent full capture. Window 10 has no screenshot. Window
# 40 has no screenshot, and its capture fails.
echo 40 > "$TMP/fail"
echo "[$(win 30 web 3 Vivaldi Docs),$(win 10 2 1 Slack ''),$(win 20 10 2 Rex shell),$(win 40 1 4 Mail Inbox)]" \
  > "$TMP/windows.json"
rm -f "$WINPEEK_CACHE"/10.*.jpg
shots30=$(ls "$WINPEEK_CACHE"/30.*.jpg)
touch "$WINPEEK_CACHE/last-capture"
out=$("$WINPEEK" list)
# The Wine window comes after the workspaces and its arg carries its pid. The
# list skips the repeated window, the helper window, and the small window.
check "list: numbered workspaces in number order, named, not tiled, focused last" \
  "10 20 30 77/500 40" "$(jq -r '[.items[].arg] | join(" ")' <<<"$out")"
check "list: a window that AeroSpace does not manage says so" "Not tiled · Game.exe" \
  "$(jq -r '.items[3].subtitle | sub(" · [0-9:]+ [AP]M$"; "")' <<<"$out")"
check "list: an empty title shows the app name" "Slack" "$(jq -r '.items[0].title' <<<"$out")"
new10=$(ls "$WINPEEK_CACHE"/10.*.jpg 2>/dev/null)
check "list: takes a screenshot only of a window that has none" "yes $shots30" \
  "$([ -n "$new10" ] && echo yes) $(ls "$WINPEEK_CACHE"/30.*.jpg)"
check "list: the icon and the Quick Look file are the screenshot" "$new10 $new10" \
  "$(jq -r '.items[0] | "\(.icon.path) \(.quicklookurl)"' <<<"$out")"
check "list: a window with no screenshot shows the app icon" "fileicon /Applications/Mail.app null" \
  "$(jq -r '.items[4] | "\(.icon.type) \(.icon.path) \(.quicklookurl)"' <<<"$out")"
check "list: the focused window says so, and the footer ends with the time" "true" \
  "$(jq -r '.items[4].subtitle | test("^Workspace 1 · Mail · focused · [0-9]{1,2}:[0-9]{2} [AP]M$")' <<<"$out")"

# After an old full capture, the list starts a full capture in the
# background.
rm -f "$TMP/fail" "$WINPEEK_CACHE/last-capture"
"$WINPEEK" list >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "$WINPEEK_CACHE/last-capture" ] && [ ! -d "$WINPEEK_CACHE/capture.lock" ] && break
  sleep 0.2
done
check "list: an old full capture starts a full capture" "yes" \
  "$([ -e "$WINPEEK_CACHE/last-capture" ] && echo yes)"

# on-focus takes a screenshot of the window that lost the focus. The first
# run only records the focused window.
rm -f "$WINPEEK_CACHE"/40.*.jpg "$WINPEEK_CACHE"/20.*.jpg
"$WINPEEK" on-focus
echo "20 2 com.test.Rex" > "$TMP/focused"
"$WINPEEK" on-focus
check "on-focus takes a screenshot of the window that lost the focus" "1 0" \
  "$(ls "$WINPEEK_CACHE"/40.*.jpg 2>/dev/null | wc -l | tr -d ' ') $(ls "$WINPEEK_CACHE"/20.*.jpg 2>/dev/null | wc -l | tr -d ' ')"

# winpeek takes no screenshot of a 1Password window, from a full capture or
# from on-focus. This includes a window that AeroSpace does not manage (91),
# such as Quick Access. The list removes an old screenshot of such a window,
# and shows the app icon.
echo "[$(win 30 web 3 Vivaldi Docs),$(win 90 1 9 1Password Vault com.1password.1password)]" > "$TMP/windows.json"
mv "$TMP/cg.json" "$TMP/cg.json.all"
echo '[{"id":91,"pid":9,"owner":"1Password","bundle":"com.1password.1password","title":"Quick Access","w":700,"h":400}]' \
  > "$TMP/cg.json"
echo old > "$WINPEEK_CACHE/90.1.jpg"
touch "$WINPEEK_CACHE/last-capture"
out=$("$WINPEEK" list)
rm -f "$WINPEEK_CACHE/last-capture"
"$WINPEEK" capture
echo "90 9 com.1password.1password" > "$TMP/focused"
"$WINPEEK" on-focus
echo "30 3 com.test.Vivaldi" > "$TMP/focused"
"$WINPEEK" on-focus
check "no screenshot of a 1Password window; the list shows the app icon" "0 0 fileicon" \
  "$(ls "$WINPEEK_CACHE"/90.*.jpg 2>/dev/null | wc -l | tr -d ' ') $(ls "$WINPEEK_CACHE"/91.*.jpg 2>/dev/null | wc -l | tr -d ' ') $(jq -r '.items[] | select(.uid == "90") | .icon.type' <<<"$out")"
mv "$TMP/cg.json.all" "$TMP/cg.json"

# A record from an older winpeek has no bundle ID, so it can be a 1Password
# window. on-focus takes no screenshot from it.
rm -f "$WINPEEK_CACHE"/30.*.jpg
echo "30 3" > "$WINPEEK_CACHE/last-focus"
echo "90 9 com.1password.1password" > "$TMP/focused"
"$WINPEEK" on-focus
check "on-focus takes no screenshot from a record with no bundle ID" "0" \
  "$(ls "$WINPEEK_CACHE"/30.*.jpg 2>/dev/null | wc -l | tr -d ' ')"

rm -f "$TMP/windows.json"
check "list: one item if AeroSpace does not answer" "AeroSpace does not answer" \
  "$("$WINPEEK" list | jq -r '.items[0].title')"

"$WINPEEK" focus 30
check "focus asks AeroSpace to focus the window" "focus --window-id 30" "$(cat "$TMP/focus.log")"

"$WINPEEK" focus 77/500
check "focus brings the app of a Wine window to the front" "yes" \
  "$(grep -q 'unix id is 500) to true' "$TMP/osascript.log" && echo yes)"
"$WINPEEK" focus '77/1 or true' 2>/dev/null
check "focus refuses a pid that is not a number" "1" "$(wc -l < "$TMP/osascript.log" | tr -d ' ')"

exit $fail
