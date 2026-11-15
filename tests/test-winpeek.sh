#!/usr/bin/env bash
# Tests for winpeek (dot_local/bin/executable_winpeek).
#
# The tests use stubs for aerospace and screencapture. They do not focus
# windows or take screenshots.
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
# missing. It logs each focus.
cat > "$TMP/bin/aerospace" <<EOF
#!/bin/bash
case "\$*" in
  *--all*) cat "$TMP/windows.json" 2>/dev/null || exit 1 ;;
  *--focused*) cat "$TMP/focused" 2>/dev/null ;;
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
# The stub of osascript prints $TMP/cg.json for the JXA window list. It logs
# each other call.
cat > "$TMP/bin/osascript" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-l" ]; then cat "$TMP/cg.json" 2>/dev/null; exit 0; fi
echo "\$*" >> "$TMP/osascript.log"
EOF
chmod +x "$TMP/bin/"*

# The macOS window list. It repeats AeroSpace window 30 and has a Wine window
# (77), a helper window with no title (78), and a small window (79).
cat > "$TMP/cg.json" <<'EOF'
[{"id":30,"pid":1,"owner":"Vivaldi","title":"Docs","w":800,"h":600},
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

win() { # id workspace app title
  printf '{"window-id":%s,"workspace":"%s","app-name":"%s","app-bundle-path":"/Applications/%s.app","window-title":"%s"}' \
    "$1" "$2" "$3" "$3" "$4"
}

echo "[$(win 30 web Vivaldi Docs),$(win 10 2 Slack ''),$(win 20 10 Rex shell),$(win 40 1 Mail Inbox)]" \
  > "$TMP/windows.json"
echo 40 > "$TMP/focused"

# A capture writes one screenshot for each window.
"$WINPEEK" capture
check "capture writes one file for each window, Wine window too" 5 "$(ls "$WINPEEK_CACHE"/*.jpg | wc -l | tr -d ' ')"

# A second capture replaces each screenshot, but keeps the old one of a
# window that it cannot capture. It removes the screenshot of a closed window.
old10=$(ls "$WINPEEK_CACHE"/10.*.jpg)
old20=$(ls "$WINPEEK_CACHE"/20.*.jpg)
echo 20 > "$TMP/fail"
echo "[$(win 30 web Vivaldi Docs),$(win 10 2 Slack ''),$(win 20 10 Rex shell)]" > "$TMP/windows.json"
rm -f "$WINPEEK_CACHE/last-capture"
"$WINPEEK" capture
new10=$(ls "$WINPEEK_CACHE"/10.*.jpg)
check "capture replaces the screenshot" "1 yes" \
  "$(ls "$WINPEEK_CACHE"/10.*.jpg | wc -l | tr -d ' ') $([ "$new10" != "$old10" ] && echo yes)"
check "a failed capture keeps the old screenshot" "$old20" "$(ls "$WINPEEK_CACHE"/20.*.jpg)"
check "capture removes the screenshot of a closed window" "" "$(ls "$WINPEEK_CACHE"/40.*.jpg 2>/dev/null)"

# The list. A recent capture means no new capture and no rerun.
echo "[$(win 30 web Vivaldi Docs),$(win 10 2 Slack ''),$(win 20 10 Rex shell),$(win 40 1 Mail Inbox)]" \
  > "$TMP/windows.json"
touch "$WINPEEK_CACHE/last-capture"
out=$("$WINPEEK" list)
# The Wine window comes after the workspaces and its arg carries its pid. The
# list skips the repeated window, the helper window, and the small window.
check "list: numbered workspaces in number order, named, not tiled, focused last" \
  "10 20 30 77/500 40" "$(jq -r '[.items[].arg] | join(" ")' <<<"$out")"
check "list: a window that AeroSpace does not manage says so" "Not tiled · Game.exe" \
  "$(jq -r '.items[3].subtitle' <<<"$out")"
check "list: an empty title shows the app name" "Slack" "$(jq -r '.items[0].title' <<<"$out")"
check "list: the icon and the Quick Look file are the screenshot" "$new10 $new10" \
  "$(jq -r '.items[0] | "\(.icon.path) \(.quicklookurl)"' <<<"$out")"
check "list: a window with no screenshot shows the app icon" "fileicon /Applications/Mail.app null" \
  "$(jq -r '.items[4] | "\(.icon.type) \(.icon.path) \(.quicklookurl)"' <<<"$out")"
check "list: the focused window says so" "Workspace 1 · Mail · focused" "$(jq -r '.items[4].subtitle' <<<"$out")"
check "list: no rerun after a recent capture" "null" "$(jq -r '.rerun' <<<"$out")"

# An old capture starts a new one, and the list asks Alfred to run it again.
rm -f "$WINPEEK_CACHE/last-capture" "$TMP/fail"
out=$("$WINPEEK" list)
check "list: an old capture starts a capture and a rerun" "0.3" "$(jq -r '.rerun' <<<"$out")"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -d "$WINPEEK_CACHE/capture.lock" ] || break; sleep 0.2; done
check "list: the capture in the background adds the missing screenshot" "1" \
  "$(ls "$WINPEEK_CACHE"/40.*.jpg 2>/dev/null | wc -l | tr -d ' ')"

rm -f "$TMP/windows.json"
check "list: one row if AeroSpace does not answer" "AeroSpace does not answer" \
  "$("$WINPEEK" list | jq -r '.items[0].title')"

"$WINPEEK" focus 30
check "focus asks AeroSpace to focus the window" "focus --window-id 30" "$(cat "$TMP/focus.log")"

"$WINPEEK" focus 77/500
check "focus brings the app of a Wine window to the front" "yes" \
  "$(grep -q 'unix id is 500) to true' "$TMP/osascript.log" && echo yes)"
"$WINPEEK" focus '77/1 or true' 2>/dev/null
check "focus refuses a pid that is not a number" "1" "$(wc -l < "$TMP/osascript.log" | tr -d ' ')"

exit $fail
