#!/usr/bin/env bash
# Source for the `tmux-windows` television channel.
# Emits display-ready lines with ANSI in the dot. tv renders the line directly
# (no `display` template) so ANSI survives; output/preview/actions extract the
# tmux target via `strip_ansi|split:\t:1`.
#
# Per-line format (tab-separated columns):
#   <dot>\t<session>:<idx>\t<window_name>
#
# State comes directly from ~/.claude/sessions/<pid>.json (written by Claude
# Code), matched to tmux windows by walking each session's process ancestry.
# No hooks or tmux window-options needed for state.
#
# The first argument selects which half of the windows to emit:
#   active  (default)  windows whose session is not held
#   hold               windows whose session name starts with `[HOLD] `
# The channel declares both as two sources, so ctrl-s switches between them.
set -u

MODE="${1:-active}"
HOLD_PREFIX="[HOLD] "

ALERTS="$HOME/.tmux/alerts"
SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"

# --- Build window_id → claude_status map from live JSON session files --------
# Walks each session pid up the process tree until it hits a known tmux pane,
# then records the window. Most-urgent status wins per window.

panes=$(tmux list-panes -a -F '#{pane_pid}	#{window_id}' 2>/dev/null)
ps_tree=$(ps -eo pid=,ppid= 2>/dev/null)

# state_rank: higher number = more urgent (determines winner per window)
state_rank() { case "$1" in waiting) echo 3;; busy) echo 2;; idle) echo 1;; *) echo 0;; esac; }

state_file=$(mktemp)
trap 'rm -f "$state_file" "${state_file}.tmp"' EXIT

for f in "$SESSIONS_DIR"/*.json; do
    [ -e "$f" ] || continue
    IFS=$'\t' read -r pid status kind < <(
        jq -r '[(.pid|tostring), (.status//""), (.kind//"")] | join("\t")' "$f" 2>/dev/null
    ) || continue
    [ "$kind" = "interactive" ] || continue
    kill -0 "$pid" 2>/dev/null || continue

    r=$(state_rank "$status")
    [ "$r" -eq 0 ] && continue

    # Walk process ancestry until we land on a tmux pane
    cur="$pid"; depth=0
    while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null && [ "$depth" -lt 30 ]; do
        wid=$(awk -F'\t' -v p="$cur" '$1==p { print $2; exit }' <<< "$panes")
        if [ -n "$wid" ]; then
            existing_rank=$(awk -F'\t' -v w="$wid" '$1==w { print $3; exit }' "$state_file")
            if [ -z "$existing_rank" ] || [ "$r" -gt "${existing_rank:-0}" ]; then
                grep -v "^${wid}	" "$state_file" > "${state_file}.tmp" 2>/dev/null \
                    && mv "${state_file}.tmp" "$state_file" || true
                printf '%s\t%s\t%s\n' "$wid" "$status" "$r" >> "$state_file"
            fi
            break
        fi
        cur=$(awk -v p="$cur" '$1==p { print $2; exit }' <<< "$ps_tree")
        depth=$((depth + 1))
    done
done

# --- Emit colored window list ------------------------------------------------

tmux list-windows -a -F '#{window_stack_index}	#{session_last_attached}	#{session_name}	#{window_index}	#{window_name}	#{window_id}' \
  | sort -t$'\t' -k1,1n -k2,2nr \
  | cut -f3- \
  | awk -F'\t' -v A="$ALERTS" -v SF="$state_file" -v MODE="$MODE" -v HP="$HOLD_PREFIX" '
      BEGIN {
        while ((getline l < SF) > 0) {
          split(l, p, "\t")
          if (p[1] != "") wstate[p[1]] = p[2]
        }
        while ((getline l < A) > 0) {
          split(l, p, "\t")
          pend[p[1]] = p[3]
        }
        RED = "\033[1;31m"
        BLU = "\033[1;34m"
        GRN = "\033[1;32m"
        DIM = "\033[2;37m"
        RST = "\033[0m"
        nrows = 0
      }
      {
        sess = $1; idx = $2; wname = $3; wid = $4
        if (sess == "mobile" || sess == "quickterminal") next
        if (wname ~ /^md:/) next

        # A held session belongs only to the `hold` source, and vice versa.
        held = (index(sess, HP) == 1)
        if (held != (MODE == "hold")) next

        # Map JSON status to color: waiting=red, busy=blue, idle=green
        state = wstate[wid]
        col = ""
        if      (state == "waiting") col = RED
        else if (state == "busy")    col = BLU
        else if (state == "idle")    col = GRN

        sub(/^[^[:alnum:]]+[[:space:]]*/, "", wname)

        # Fallback: logged bell/activity alert if no live JSON state
        key = sess ":" idx
        if (col == "" && key in pend) {
          t = pend[key]
          if      (t == "BELL")     col = RED
          else if (t == "ACTIVITY") col = DIM
          else                      col = GRN
        }

        dot = (col != "") ? col "●" RST : " "
        printf "%s\t%s:%s\t%s\n", dot, sess, idx, wname
        nrows++
      }
      END {
        if (nrows == 0) {
          msg = (MODE == "hold") ? "no sessions on hold" : "no working sessions"
          printf "%s\t\t%s\n", DIM "-" RST, DIM msg RST
        }
      }
    '
