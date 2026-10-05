#!/usr/bin/env bash
# Tests for the groups of the window picker: active, hold (prefix+b), and the
# utility sessions.
#
# Runs against a private tmux socket, so it cannot touch the live server.
set -u

# Source-tree names carry the chezmoi `executable_` prefix.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOGGLE="$script_dir/executable_toggle-hold.sh"
PICKER="$script_dir/executable_tv-tmux-windows.sh"
CYCLE="$script_dir/executable_cycle-windows.sh"

SOCKET="hold-test-$$"
sessions_dir=$(mktemp -d)
shim_dir=$(mktemp -d)
alerts_home=$(mktemp -d)
cache_tmp=$(mktemp -d)

tm() { command tmux -L "$SOCKET" "$@"; }
cleanup() { tm kill-server 2>/dev/null; rm -rf "$sessions_dir" "$shim_dir" "$alerts_home" "$cache_tmp"; }
trap cleanup EXIT

pass=0
fail=0
check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$label"
        pass=$((pass + 1))
    else
        printf 'FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$label" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

# The scripts call `tmux` by name. Shadow it with a wrapper that pins the test
# socket, so nothing reaches the live server.
cat > "$shim_dir/tmux" <<SHIM
#!/usr/bin/env bash
exec $(command -v tmux) -L "$SOCKET" "\$@"
SHIM
chmod +x "$shim_dir/tmux"

# An empty HOME gives the picker no alert log and no Claude state, so every
# row comes out undecorated and the test reads only the filtering.
# XDG_CACHE_HOME keeps the cache of the last output out of the real one.
run() { PATH="$shim_dir:$PATH" HOME="$alerts_home" XDG_CACHE_HOME="$cache_tmp" CLAUDE_SESSIONS_DIR="$sessions_dir" bash "$@"; }

# Rows look like `●  <session> │ <idx> │ <window> │ ...`. This rebuilds the
# `session:index` target the same way as the channel, minus the colour codes.
# The message row of an empty group has no `│`, so it gives no target.
strip() { run "$PICKER" "$1" | sed 's/\x1b\[[0-9;]*m//g'; }
picker() {
    strip "$1" \
        | awk -F'│' 'NF > 1 { s = $1; sub(/^● +/, "", s); sub(/ +$/, "", s); i = $2; gsub(/ /, "", i); print s ":" i }' \
        | sort | tr '\n' ' ' | sed 's/ *$//'
}

# Walk the real cycler forward from `start` until it comes back round, so the
# assertions cover cycle-windows.sh itself rather than a copy of its filter.
rotation_set() {
    local start=$1 cur=$1 seen=""
    for _ in 1 2 3 4 5 6 7 8; do
        cur=$(CYCLE_DRY_RUN=1 run "$CYCLE" next "$cur")
        [ -n "$cur" ] || break
        case " $seen " in *" $cur "*) break ;; esac
        seen="$seen $cur"
    done
    printf '%s' "$seen" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ *$//'
}

session_names() { tm list-sessions -F '#{session_name}' | sort | tr '\n' ' ' | sed 's/ *$//'; }

# --- fixture ----------------------------------------------------------------
# Headless, tmux treats the newest session as current, and toggle-hold.sh acts
# on the current session. Create bravo last so the toggle lands on it.
tm new-session -d -s quickterminal
tm new-session -d -s alpha
tm new-session -d -s charlie
tm new-session -d -s bravo

check "active source lists every work session" "alpha:0 bravo:0 charlie:0" "$(picker active)"
check "hold source is empty"              ""                          "$(picker hold | grep -o '.*' || true)"
check "rotation covers every work session" "alpha:0 bravo:0 charlie:0" "$(rotation_set alpha:0)"

# --- utility sessions -------------------------------------------------------

check "other source lists the utility session" "quickterminal:0"       "$(picker other)"
check "rotation steps over the utility session" "alpha:0 bravo:0 charlie:0" "$(rotation_set alpha:0)"

# --- toggle on --------------------------------------------------------------
run "$TOGGLE" >/dev/null

check "toggle marks the current session"     "[HOLD] bravo alpha charlie quickterminal" "$(session_names)"
check "held session leaves the active source" "alpha:0 charlie:0"         "$(picker active)"
check "held session appears in the hold source" "[HOLD] bravo:0"          "$(picker hold)"
check "rotation steps over the held session"  "alpha:0 charlie:0"         "$(rotation_set alpha:0)"

# --- toggle off -------------------------------------------------------------
run "$TOGGLE" >/dev/null

check "toggle clears the marker"            "alpha bravo charlie quickterminal"       "$(session_names)"
check "session returns to the active source" "alpha:0 bravo:0 charlie:0" "$(picker active)"
check "rotation covers it again"             "alpha:0 bravo:0 charlie:0" "$(rotation_set alpha:0)"

# --- empty-state message ----------------------------------------------------
check "hold source explains an empty list" \
    "no sessions on hold" \
    "$(strip hold | sed 's/^● *//')"

tm kill-session -t quickterminal
check "other source explains an empty list" \
    "no other sessions" \
    "$(strip other | sed 's/^● *//')"

# --- two Claude panes in one window -----------------------------------------
# Each pane runs `sleep`, so the pane pid is a live process that stands in for
# Claude. Both sessions are idle. The one whose status changed last must win.
tm new-session -d -s delta 'sleep 300'
tm split-window -t delta 'sleep 300'
pane_pids=($(tm list-panes -t delta -F '#{pane_pid}'))
project_dir="$alerts_home/.claude/projects/-tmp-delta"
mkdir -p "$project_dir"
fake_claude() {
    local pid=$1 sid=$2 changed=$3 text=$4
    printf '{"pid":%s,"sessionId":"%s","cwd":"/tmp/delta","kind":"interactive","status":"idle","statusUpdatedAt":%s}\n' \
        "$pid" "$sid" "$changed" > "$sessions_dir/$pid.json"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' \
        "$text" > "$project_dir/$sid.jsonl"
}
fake_claude "${pane_pids[0]}" "older-$$" 1000 "older pane"
fake_claude "${pane_pids[1]}" "newer-$$" 2000 "newer pane"

check "a window with two Claude panes shows the count and the newer output" \
    "2× newer pane" \
    "$(strip active | awk -F' │ ' '$1 ~ /delta/ { print $4 }')"

# A waiting pane is more urgent than an idle one, so it wins although its
# status is older. The row says why it waits.
jq -c '.status = "waiting" | .waitingFor = "input needed"' "$sessions_dir/${pane_pids[0]}.json" \
    > "$sessions_dir/tmp" && mv "$sessions_dir/tmp" "$sessions_dir/${pane_pids[0]}.json"
check "a waiting pane wins and the row says why it waits" \
    "2× ◆ input needed · older pane" \
    "$(strip active | awk -F' │ ' '$1 ~ /delta/ { print $4 }')"

# The cache holds transcript text, so only the owner can read it.
check "the cache directory is private" \
    "700" "$(stat -f '%Lp' "$cache_tmp/tv-tmux-windows")"
check "each cache file is private" \
    "600" "$(stat -f '%Lp' "$cache_tmp/tv-tmux-windows"/* | sort -u | tr '\n' ' ' | sed 's/ *$//')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
