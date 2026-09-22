#!/usr/bin/env bash
# Tests for the [HOLD] session marker (prefix+b).
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

tm() { command tmux -L "$SOCKET" "$@"; }
cleanup() { tm kill-server 2>/dev/null; rm -rf "$sessions_dir" "$shim_dir" "$alerts_home"; }
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
run() { PATH="$shim_dir:$PATH" HOME="$alerts_home" CLAUDE_SESSIONS_DIR="$sessions_dir" bash "$@"; }

# Column 2 of each row is the `session:index` target, minus the colour codes.
picker() { run "$PICKER" "$1" | sed 's/\x1b\[[0-9;]*m//g' | cut -f2 | sort | tr '\n' ' ' | sed 's/ *$//'; }

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
tm new-session -d -s alpha
tm new-session -d -s charlie
tm new-session -d -s bravo

check "active source lists every session" "alpha:0 bravo:0 charlie:0" "$(picker active)"
check "hold source is empty"              ""                          "$(picker hold | grep -o '.*' || true)"
check "rotation covers every session"     "alpha:0 bravo:0 charlie:0" "$(rotation_set alpha:0)"

# --- toggle on --------------------------------------------------------------
run "$TOGGLE" >/dev/null

check "toggle marks the current session"     "[HOLD] bravo alpha charlie" "$(session_names)"
check "held session leaves the active source" "alpha:0 charlie:0"         "$(picker active)"
check "held session appears in the hold source" "[HOLD] bravo:0"          "$(picker hold)"
check "rotation steps over the held session"  "alpha:0 charlie:0"         "$(rotation_set alpha:0)"

# --- toggle off -------------------------------------------------------------
run "$TOGGLE" >/dev/null

check "toggle clears the marker"            "alpha bravo charlie"       "$(session_names)"
check "session returns to the active source" "alpha:0 bravo:0 charlie:0" "$(picker active)"
check "rotation covers it again"             "alpha:0 bravo:0 charlie:0" "$(rotation_set alpha:0)"

# --- empty-state message ----------------------------------------------------
check "hold source explains an empty list" \
    "no sessions on hold" \
    "$(run "$PICKER" hold | sed 's/\x1b\[[0-9;]*m//g' | cut -f3)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
