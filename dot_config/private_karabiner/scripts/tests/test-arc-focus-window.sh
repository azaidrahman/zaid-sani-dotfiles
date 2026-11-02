#!/usr/bin/env bash
# Tests for arc-focus-window.sh. The tests replace aerospace and osascript
# with stubs, so they do not change the focus on your desktop.
#
# Each case sets these values for the stubs:
#   WINDOWS  the lines that "aerospace list-windows" prints: <id>|<title>
#   INFO     the line that the Arc query prints:
#            <Arc id><TAB><rank><TAB><main><TAB><title>
#   STACK    the aerospace ids of the Arc windows, front to back
# The case then checks the exit status, the output, and the calls that the
# script makes. The window must be the main window of Arc before aerospace
# focuses it. If the Arc query did not make it the main window, make_main
# must do it.
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
# id prints the order of the windows. The AppleScript call is the Arc query.
cat > "$TMP/bin/osascript" <<'EOF'
#!/bin/sh
cat > /dev/null
if [ "${1:-}" != "-l" ]; then [ -z "$STUB_INFO" ] || printf '%s\n' "$STUB_INFO"
elif [ -n "${4:-}" ]; then echo "main $4" >> "$STUB_LOG"
# shellcheck disable=SC2086 # Split STUB_STACK into one id for each line.
else printf '%s\n' $STUB_STACK; fi
EOF
chmod +x "$TMP/bin/aerospace" "$TMP/bin/osascript"

# run <label> <expected status> <expected output and calls> <windows> <info> <stack>
run() {
  : > "$TMP/log"
  out=$(PATH="$TMP/bin:$PATH" AEROSPACE_BIN="$TMP/bin/aerospace" STUB_LOG="$TMP/log" \
    STUB_WINDOWS="$4" STUB_INFO="$5" STUB_STACK="$6" ARC_FOCUS_TRIES=2 \
    sh "$SCRIPT" space Research 2>/dev/null)
  rc=$?
  actual=$(printf 'out=%s ' "$out"; tr '\n' ' ' < "$TMP/log")
  actual=${actual% }
  if [ "$rc" = "$2" ] && [ "$actual" = "$3" ]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s\n      expected: %s (exit %s)\n      actual:   %s (exit %s)\n' \
    "$1" "$3" "$2" "$actual" "$rc"; fail=1; fi
}

T=$(printf '\t')
# 9121 is the Work window. Aerospace lists it before the Research window 12636.
TWO_LESSONS="9121|Lesson | KodeKloud
11724|LOFI
12636|Lesson | KodeKloud"

run "a unique title that the query made main" 0 "out=W2 focus 11724" \
  "$TWO_LESSONS" "W2${T}0${T}1${T}LOFI" "9121 12636 11724"
run "the same title: the front window is rank 0" 0 "out=W3 main 12636 focus 12636" \
  "$TWO_LESSONS" "W3${T}0${T}0${T}Lesson | KodeKloud" "12636 9121 11724"
run "the same title: rank 1 is the second window from the front" 0 "out=W3 main 12636 focus 12636" \
  "$TWO_LESSONS" "W3${T}1${T}0${T}Lesson | KodeKloud" "11724 9121 12636"
run "no aerospace window with the title focuses nothing" 1 "out=W9" \
  "$TWO_LESSONS" "W9${T}0${T}1${T}Closed tab" "9121 12636 11724"
run "no window shows the space: exit 3 for a new window" 3 "out=" \
  "$TWO_LESSONS" "" "9121 12636 11724"

exit "$fail"
