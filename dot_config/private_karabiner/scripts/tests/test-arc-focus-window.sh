#!/usr/bin/env bash
# Tests for arc-focus-window.sh. The tests replace aerospace and osascript
# with stubs, so they do not change the focus on your desktop.
#
# Each case sets these values for the stubs:
#   WINDOWS  the lines that "aerospace list-windows" prints: <id>|<title>
#   INFO     the line that the Arc query prints: <rank><TAB><name>
#   STACK    the aerospace ids of the Arc windows, front to back
# The case then checks the calls that the script makes. The script must make
# the window the main window of Arc before aerospace focuses it.
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/executable_arc-focus-window.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

mkdir "$TMP/bin"
cat > "$TMP/bin/aerospace" <<'EOF'
#!/bin/sh
case "$1" in
  list-windows) printf '%s\n' "$STUB_WINDOWS" ;;
  focus) echo "focus $3" >> "$STUB_LOG" ;;
esac
EOF
# The JavaScript call with an id is make_main. The JavaScript call without an
# id prints the order of the windows.
cat > "$TMP/bin/osascript" <<'EOF'
#!/bin/sh
cat > /dev/null
if [ "${1:-}" != "-l" ]; then printf '%s\n' "$STUB_INFO"
elif [ -n "${4:-}" ]; then echo "main $4" >> "$STUB_LOG"
# shellcheck disable=SC2086 # Split STUB_STACK into one id for each line.
else printf '%s\n' $STUB_STACK; fi
EOF
chmod +x "$TMP/bin/aerospace" "$TMP/bin/osascript"

# run <label> <expected focus> <windows> <info> <stack>
# Use "none" as the expected focus for a case that must focus no window and
# must exit with an error.
run() {
  : > "$TMP/log"
  PATH="$TMP/bin:$PATH" AEROSPACE_BIN="$TMP/bin/aerospace" STUB_LOG="$TMP/log" \
    STUB_WINDOWS="$3" STUB_INFO="$4" STUB_STACK="$5" ARC_FOCUS_TRIES=2 \
    sh "$SCRIPT" "ARC-WINDOW-ID" 2>/dev/null
  rc=$?
  actual=$(tr '\n' ' ' < "$TMP/log" | sed 's/ $//')
  if [ "$2" = none ]; then
    [ "$rc" -ne 0 ] && [ -z "$actual" ] && ok=1 || ok=0
  else
    [ "$rc" -eq 0 ] && [ "$actual" = "$2" ] && ok=1 || ok=0
  fi
  if [ "$ok" = 1 ]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s\n      expected: %s\n      actual:   %s (exit %s)\n' "$1" "$2" "$actual" "$rc"; fail=1; fi
}

T=$(printf '\t')
# 9121 is the Work window. Aerospace lists it before the Research window 12636.
TWO_LESSONS="9121|Lesson | KodeKloud
11724|LOFI
12636|Lesson | KodeKloud"

run "a unique title focuses that window" "main 11724 focus 11724" \
  "$TWO_LESSONS" "0${T}LOFI" "9121 12636 11724"
run "the same title: the front window is rank 0" "main 12636 focus 12636" \
  "$TWO_LESSONS" "0${T}Lesson | KodeKloud" "12636 9121 11724"
run "the same title: rank 1 is the second window from the front" "main 12636 focus 12636" \
  "$TWO_LESSONS" "1${T}Lesson | KodeKloud" "11724 9121 12636"
run "no window with the title focuses nothing" none \
  "$TWO_LESSONS" "0${T}Closed tab" "9121 12636 11724"

exit "$fail"
