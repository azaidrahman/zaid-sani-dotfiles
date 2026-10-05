#!/usr/bin/env bash
# Source for the `tmux-windows` television channel.
# Emits display-ready lines with ANSI colors. tv renders the line directly
# (no `display` template) so ANSI survives.
#
# Per-line format (columns padded with spaces and separated by " │ "):
#   ●  <session> │ <idx> │ <window_name> │ <last Claude output>
#
# The channel gets the tmux target from the first two columns with
# `strip_ansi|split:│:N|trim`, so `│` must not appear in a column. The last
# column is present only for a window that runs Claude.
#
# State comes directly from ~/.claude/sessions/<pid>.json (written by Claude
# Code), matched to tmux windows by walking each session's process ancestry.
# No hooks or tmux window-options needed for state.
#
# The last output is the most recent text or tool call of the assistant in the
# transcript of the session. It is cached by the mtime and size of the
# transcript, because tv runs this script every 0.5 seconds.
#
# The first argument selects which group of windows to emit:
#   active  (default)  windows of a normal session that is not held
#   hold               windows whose session name starts with `[HOLD] `
#   other              windows of a utility session (mobile, quickterminal)
# The channel declares all three as sources, so ctrl-s switches between them.
set -u

MODE="${1:-active}"
HOLD_PREFIX="[HOLD] "
# Utility sessions. They are not work, so they get their own group.
UTIL_SESSIONS="mobile quickterminal"

ALERTS="$HOME/.tmux/alerts"
SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
CACHE_DIR="${TMPDIR:-/tmp}/tv-tmux-windows"

# --- Build window_id → claude_status map from live JSON session files --------
# Walks each session pid up the process tree until it hits a known tmux pane,
# then records the window. Most-urgent status wins per window. If two panes
# have the same status, the one whose status changed last wins, so the last
# output shows the newest activity.

panes=$(tmux list-panes -a -F '#{pane_pid}	#{window_id}' 2>/dev/null)
ps_tree=$(ps -eo pid=,ppid= 2>/dev/null)

# state_rank: higher number = more urgent (determines winner per window)
state_rank() { case "$1" in waiting) echo 3;; busy) echo 2;; idle) echo 1;; *) echo 0;; esac; }

state_file=$(mktemp)
preview_file=$(mktemp)
# One line per Claude pane, with its window ID. Used to count the panes.
pane_file=$(mktemp)
trap 'rm -f "$state_file" "${state_file}.tmp" "$preview_file" "$pane_file"' EXIT

for f in "$SESSIONS_DIR"/*.json; do
    [ -e "$f" ] || continue
    # waitingFor says why a `waiting` session needs you, for example
    # "input needed" or the name of a permission dialog.
    IFS=$'\t' read -r pid status kind sid cwd changed waiting_for < <(
        jq -r '[(.pid|tostring), (.status//""), (.kind//""), (.sessionId//""), (.cwd//""),
                ((.statusUpdatedAt // .updatedAt // 0)|tostring),
                ((.waitingFor // "") | gsub("[\\t│]"; " "))] | join("\t")' "$f" 2>/dev/null
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
            printf '%s\n' "$wid" >> "$pane_file"
            IFS=$'\t' read -r existing_rank existing_changed < <(
                awk -F'\t' -v w="$wid" '$1==w { print $3 "\t" $6; exit }' "$state_file"
            )
            if [ -z "${existing_rank:-}" ] || [ "$r" -gt "$existing_rank" ] \
                || { [ "$r" -eq "$existing_rank" ] && [ "${changed:-0}" -gt "${existing_changed:-0}" ]; }; then
                # grep exits 1 when no other line remains, so do not chain mv on it.
                grep -v "^${wid}	" "$state_file" > "${state_file}.tmp" 2>/dev/null
                mv "${state_file}.tmp" "$state_file"
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$wid" "$status" "$r" "$sid" "$cwd" "$changed" "$waiting_for" >> "$state_file"
            fi
            break
        fi
        cur=$(awk -v p="$cur" '$1==p { print $2; exit }' <<< "$ps_tree")
        depth=$((depth + 1))
    done
done

# --- Last output of the Claude session that won each window -----------------

# Prints the most recent text or tool call of the assistant as one short line.
# Partial JSON lines from `tail` are skipped by `fromjson?`.
LAST_OUTPUT_JQ='
  fromjson? | select(.type == "assistant") | .message.content[]?
  | if .type == "text" then
      .text
      | gsub("\\[(?<t>[^\\]]*)\\]\\([^)]*\\)"; "\(.t)")
      | gsub("\\*\\*|__|`|^#+ "; "")
    elif .type == "tool_use" then
      "▸ " + .name + ": " + ((
        .input.description // .input.command // .input.file_path
        // .input.pattern // .input.questions[0].question // .input.skill
        // .input.prompt // "") | tostring)
    else empty end
  | gsub("[\\s│]+"; " ") | ltrimstr(" ") | select(length > 0) | .[0:120]
'

# One `stat` call gives the stamp of each transcript. A cache hit then needs
# no other process, because the slug and the cache read use bash builtins.
wids=(); sids=(); transcripts=()
while IFS=$'\t' read -r wid _ _ sid cwd _; do
    [ -n "$sid" ] || continue
    # Claude Code names the project directory after the cwd, with each
    # character that is not alphanumeric changed to `-`.
    t="$PROJECTS_DIR/${cwd//[^A-Za-z0-9]/-}/$sid.jsonl"
    [ -f "$t" ] || continue
    wids+=("$wid"); sids+=("$sid"); transcripts+=("$t")
done < "$state_file"

if [ "${#transcripts[@]}" -gt 0 ]; then
    stamps=()
    while read -r s; do stamps+=("$s"); done < <(
        stat -f '%m.%z' "${transcripts[@]}" 2>/dev/null || stat -c '%Y.%s' "${transcripts[@]}" 2>/dev/null
    )
    mkdir -p "$CACHE_DIR"
    for i in "${!transcripts[@]}"; do
        cache="$CACHE_DIR/${sids[$i]}"
        cached_stamp=""; out=""
        [ -f "$cache" ] && { read -r cached_stamp; read -r out; } < "$cache"
        if [ "$cached_stamp" != "${stamps[$i]:-}" ]; then
            out=$(tail -n 300 "${transcripts[$i]}" | jq -Rr "$LAST_OUTPUT_JQ" 2>/dev/null | tail -n 1)
            printf '%s\n%s\n' "${stamps[$i]:-}" "$out" > "$cache"
        fi
        [ -n "$out" ] && printf '%s\t%s\n' "${wids[$i]}" "$out" >> "$preview_file"
    done
fi

# --- Emit colored window list ------------------------------------------------

tmux list-windows -a -F '#{window_stack_index}	#{session_last_attached}	#{session_name}	#{window_index}	#{window_name}	#{window_id}' \
  | sort -t$'\t' -k1,1n -k2,2nr \
  | cut -f3- \
  | awk -F'\t' -v A="$ALERTS" -v SF="$state_file" -v PF="$preview_file" -v CF="$pane_file" -v MODE="$MODE" -v HP="$HOLD_PREFIX" -v UTIL="$UTIL_SESSIONS" '
      # A color per session name, so windows of one session stand out. The
      # hash of the name picks the start slot, so a session keeps its color.
      # If another session in this list holds that slot, try the next one.
      function sess_color(s,    i, h, c) {
        if (s in scol) return scol[s]
        h = 0
        for (i = 1; i <= length(s); i++) h = (h * 31 + ord[substr(s, i, 1)]) % 1000003
        for (i = 0; i < npal; i++) {
          c = (h + i) % npal + 1
          if (!(c in taken)) break
        }
        taken[c] = 1
        scol[s] = "\033[38;5;" palette[c] "m"
        return scol[s]
      }
      function clip(s, w) {
        return (length(s) > w) ? substr(s, 1, w - 1) "…" : s
      }
      function pad(s, w) {
        return s sprintf("%" (w - length(s)) "s", "")
      }
      BEGIN {
        while ((getline l < SF) > 0) {
          split(l, p, "\t")
          if (p[1] != "") { wstate[p[1]] = p[2]; wwait[p[1]] = p[7] }
        }
        while ((getline l < PF) > 0) {
          t = index(l, "\t")
          if (t > 0) wprev[substr(l, 1, t - 1)] = substr(l, t + 1)
        }
        while ((getline l < CF) > 0) npanes[l]++
        while ((getline l < A) > 0) {
          split(l, p, "\t")
          pend[p[1]] = p[3]
        }
        for (i = 32; i < 127; i++) ord[sprintf("%c", i)] = i
        npal = split("81 213 221 141 114 209 75 176 186 116", palette, " ")
        # Fixed 24-bit colors for the state dots. The basic ANSI colors come
        # from the terminal theme, and its blue is too dark to see on the
        # selection background of tv (#44475a).
        RED = "\033[1;38;2;255;85;85m"
        BLU = "\033[1;38;2;96;165;250m"
        GRN = "\033[1;38;2;74;222;128m"
        DIM = "\033[2;37m"
        GRY = "\033[90m"
        IDX = "\033[33m"
        BLD = "\033[1m"
        PRV = "\033[2;3m"
        RST = "\033[0m"
        SEP = " " GRY "│" RST " "
        MAXNAME = 34
        nrows = 0
        wsess = 0; widx = 0; wname_w = 0
        split(UTIL, u, " ")
        for (i in u) util[u[i]] = 1
      }
      {
        sess = $1; idx = $2; wname = $3; wid = $4
        if (wname ~ /^md:/) next

        # Each window belongs to one group only. A utility session is never
        # work, so it wins over the hold marker.
        if (sess in util)            group = "other"
        else if (index(sess, HP) == 1) group = "hold"
        else                         group = "active"
        if (group != MODE) next

        # Map JSON status to color: waiting=red, busy=blue, idle=green
        state = wstate[wid]
        col = ""
        if      (state == "waiting") col = RED
        else if (state == "busy")    col = BLU
        else if (state == "idle")    col = GRN

        sub(/^[^[:alnum:]]+[[:space:]]*/, "", wname)
        gsub(/│/, "|", wname)

        # Fallback: logged bell/activity alert if no live JSON state
        key = sess ":" idx
        if (col == "" && key in pend) {
          t = pend[key]
          if      (t == "BELL")     col = RED
          else if (t == "ACTIVITY") col = DIM
          else                      col = GRN
        }

        # The dot is always printed: the channel splits the first column on it.
        nrows++
        r_dot[nrows]  = ((col != "") ? col : GRY) "●" RST
        r_sess[nrows] = sess
        r_idx[nrows]  = idx
        r_name[nrows] = clip(wname, MAXNAME)
        r_prev[nrows] = wprev[wid]
        r_wait[nrows] = (state == "waiting") ? wwait[wid] : ""
        r_count[nrows] = npanes[wid] + 0
        if (length(sess) > wsess)            wsess = length(sess)
        if (length(idx) > widx)              widx = length(idx)
        if (length(r_name[nrows]) > wname_w) wname_w = length(r_name[nrows])
      }
      END {
        for (i = 1; i <= nrows; i++) {
          # The session name is never cut, because the channel needs the full
          # name for the tmux target.
          line = r_dot[i] "  " sess_color(r_sess[i]) pad(r_sess[i], wsess) RST \
                 SEP IDX pad(r_idx[i], widx) RST \
                 SEP BLD pad(r_name[i], wname_w) RST
          # If the window has more than one Claude pane, show the count. The
          # last output then comes from the pane that won the window.
          if (r_count[i] > 1) cnt = GRY r_count[i] "×" RST " "
          else                cnt = ""
          # If Claude waits for you, say why before the last output.
          if (r_wait[i] != "") wait = RED "◆ " r_wait[i] RST GRY " · " RST
          else                 wait = ""
          if (cnt != "" || wait != "" || r_prev[i] != "") line = line SEP cnt wait PRV r_prev[i] RST
          print line
        }
        if (nrows == 0) {
          if      (MODE == "hold")  msg = "no sessions on hold"
          else if (MODE == "other") msg = "no other sessions"
          else                      msg = "no working sessions"
          printf "%s  %s\n", GRY "●" RST, DIM msg RST
        }
      }
    '
