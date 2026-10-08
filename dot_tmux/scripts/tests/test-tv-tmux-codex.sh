#!/usr/bin/env bash
# Test Codex states and output on a private tmux server.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d)
socket="tv-codex-test-$$"
tm() { command tmux -L "$socket" -f /dev/null "$@"; }
cleanup() { tm kill-server 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/tmux" <<SHIM
#!/usr/bin/env bash
exec $(command -v tmux) -L "$socket" -f /dev/null "\$@"
SHIM
chmod +x "$tmp/bin/tmux"
# Use a real process named codex to test discovery through a pane's shell.
cc -x c -o "$tmp/codex" - <<'C'
#include <unistd.h>
int main(void) { sleep(300); return 0; }
C
fixture() {
    local name=$1 text=$2
    printf '%s\n' "$text" > "$tmp/$name.txt"
    tm new-session -d -s "$name" -x 160 -y 40 \
        "cat '$tmp/$name.txt'; '$tmp/codex' 300 & wait"
}
fixture idle $'• Fixed the **parser**.\n  It now handles both agents.\n\n› Ask Codex to do anything\n\n  GPT-6 · Context 90% left'
fixture busy $'• Read the config.\n\n• Working (2s • esc to interrupt)\n\n› Ask Codex to do anything'
fixture waiting $'• Check the file.\n\n• Working (5s • esc to interrupt)\n\n  Would you like to run the following command?\n\n  $ cat file\n\n› 1. Yes, proceed (y)\n\n  Press enter to confirm or esc to cancel'
fixture ordinary $'• This is not a Codex pane.\n\n• Working (1s • esc to interrupt)'
tm respawn-pane -k -t ordinary 'sleep 300'
sleep 0.2
run() {
    PATH="$tmp/bin:$PATH" HOME="$tmp/home" XDG_CACHE_HOME="$tmp/home/cache" \
        bash "$script_dir/executable_tv-tmux-windows.sh" active
}
plain() { run | sed 's/\x1b\[[0-9;]*m//g'; }
check() {
    if [ "$2" != "$3" ]; then
        printf 'FAIL %s\nexpected: %s\nactual: %s\n' "$1" "$2" "$3" >&2
        plain >&2
        exit 1
    fi
    printf 'ok %s\n' "$1"
}
state() {
    run | awk -v name="$1" '
        index($0, name) {
            if ($0 ~ /^\033\[1;38;2;255;85;85m/) print "waiting"
            else if ($0 ~ /^\033\[1;38;2;96;165;250m/) print "busy"
            else if ($0 ~ /^\033\[1;38;2;74;222;128m/) print "idle"
            else print "none"
        }'
}
check 'Codex idle state' idle "$(state idle)"
check 'Codex busy state' busy "$(state busy)"
check 'Codex approval state' waiting "$(state waiting)"
check 'ordinary panes have no agent state' none "$(state ordinary)"
check 'Codex output includes wrapped text' 'Fixed the parser. It now handles both agents.' \
    "$(plain | awk -F' │ ' '$1 ~ /idle/ {print $4}')"
check 'Codex approval explains the wait' '◆ approval needed · Check the file.' \
    "$(plain | awk -F' │ ' '$1 ~ /waiting/ {print $4}')"
check 'Codex windows use the state order' 'waiting idle busy ordinary' \
    "$(plain | awk -F' │ ' '{s=$1; sub(/^● +/, "", s); sub(/ +$/, "", s); print s}' | paste -sd ' ' -)"

# An idle Claude pane must not override a busy Codex pane in the same window.
tm split-window -t busy 'sleep 300'
pid=$(tm list-panes -t busy -F '#{pane_pid}' | tail -n 1)
mkdir -p "$tmp/home/.claude/sessions"
printf '{"pid":%s,"kind":"interactive","status":"idle","statusUpdatedAt":9999999999999}\n' \
    "$pid" > "$tmp/home/.claude/sessions/$pid.json"
check 'mixed agents use the most urgent state' busy "$(state busy)"
check 'mixed agents count their panes' '2× Read the config.' \
    "$(plain | awk -F' │ ' '$1 ~ /busy/ {print $4}')"

tm respawn-pane -k -t idle "printf '• Working (2s • esc to interrupt)\n\n• Done.\n\n› Ask Codex to do anything\n'; '$tmp/codex' 300 & wait"
sleep 0.2
check 'old progress lines do not mark completed output busy' idle "$(state idle)"
tm respawn-pane -k -t waiting "printf '• Check the file.\n\n  Which file?\n\n› 1. The config\n\n  Enter to submit\n'; '$tmp/codex' 300 & wait"
sleep 0.2
check 'Codex questions explain the wait' '◆ input needed · Check the file.' \
    "$(plain | awk -F' │ ' '$1 ~ /waiting/ {print $4}')"

tm respawn-pane -k -t idle 'sleep 300'
check 'closed Codex processes leave no stale state' none "$(state idle)"
printf 'All Codex picker tests passed.\n'
