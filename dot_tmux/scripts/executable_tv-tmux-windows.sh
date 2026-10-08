#!/usr/bin/env bash
# Source for the `tmux-windows` television channel.
# Emits display-ready lines with ANSI colors. tv renders the line directly
# (no `display` template) so ANSI survives.
#
# Per-line format (columns padded with spaces and separated by " │ "):
#   ●  <session> │ <idx> │ <window_name> │ <last agent output>
#
# The channel gets the tmux target from the first two columns with
# `strip_ansi|split:│:N|trim`, so `│` must not appear in a column. The last
# column is present only for a window that runs an agent.
#
# State comes directly from ~/.claude/sessions/<pid>.json (written by Claude
# Code), matched to tmux windows by walking each session's process ancestry.
# Codex uses a shared daemon. Read each live client's pane for its state and
# output, because the daemon's process ancestry does not identify the pane.
#
# For Claude, read the last assistant text or tool call from the transcript.
# Cache it by the transcript's modification time and size. Read Codex output
# from the pane, because tv runs this script every second.
#
# The first argument selects which group of windows to emit:
#   active  (default)  windows of a normal session that is not held
#   hold               windows whose session name starts with `[HOLD] `
#   other              windows of a utility session (mobile, quickterminal)
# The channel declares all three as sources, so ctrl-f switches between them.
set -u

MODE="${1:-active}"
HOLD_PREFIX="[HOLD] "
# Utility sessions. They are not work, so they get their own group.
UTIL_SESSIONS="mobile quickterminal"

ALERTS="$HOME/.tmux/alerts"
SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
# The cache holds text from the transcripts, so it must be private. It is
# under the home directory, not in a shared temporary directory.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tv-tmux-windows"

# --- Build the state map for each window ------------------------------------
# Walks each session pid up the process tree until it hits a known tmux pane,
# then records the window. Most-urgent status wins per window. If two panes
# have the same status, prefer the latest Claude timestamp. Codex has no
# timestamp in its display, so use zero for its timestamp.
#
# Read Claude files in one batch. Capture only panes with a live Codex client.

state_file=$(mktemp)
preview_file=$(mktemp)
# One line per agent pane, with its window ID. Used to count the panes.
pane_file=$(mktemp)
panes_file=$(mktemp)
ps_file=$(mktemp)
sessions_file=$(mktemp)
codex_file=$(mktemp)
trap 'rm -f "$state_file" "$preview_file" "$pane_file" "$panes_file" "$ps_file" "$sessions_file" "$codex_file"' EXIT

tmux list-panes -a -F '#{pane_pid}	#{window_id}	#{pane_id}' > "$panes_file" 2>/dev/null
ps -eo pid=,ppid=,comm= > "$ps_file" 2>/dev/null

# waitingFor says why a `waiting` session needs you, for example
# "input needed" or the name of a permission dialog.
SESSION_JQ='select(.kind == "interactive")
    | [(.pid|tostring), (.status//""), (.sessionId//""), (.cwd//""),
       ((.statusUpdatedAt // .updatedAt // 0)|tostring),
       ((.waitingFor // "") | gsub("[\\t│]"; " "))] | join("\t")'
session_files=("$SESSIONS_DIR"/*.json)
if [ -e "${session_files[0]}" ]; then
    # A parse error stops jq, and the files after the bad one are lost. Claude
    # Code can be in the middle of a write, so awk puts each file on one line,
    # and `fromjson?` skips only the line that does not parse. A newline in
    # JSON is only whitespace, so a join with a space keeps the JSON valid.
    awk 'FNR == 1 && NR > 1 { print "" } { printf "%s ", $0 } END { if (NR) print "" }' \
        "${session_files[@]}" 2>/dev/null \
        | jq -rR "fromjson? | $SESSION_JQ" > "$sessions_file" 2>/dev/null
fi

# Find Codex clients through their pane shells. Exclude the shared daemon,
# which has no pane ancestor. Record each pane once.
awk -v PANES="$panes_file" '
    BEGIN {
        while ((getline l < PANES) > 0) { split(l, p, "\t"); pane[p[1]] = p[3] }
    }
    { parent[$1] = $2; if ($0 ~ /(^|[ \/])codex$/) clients[$1] = 1 }
    END {
        for (pid in clients) {
            cur = pid
            for (depth = 0; cur > 1 && depth < 30; depth++) {
                if (cur in pane) {
                    if (!(cur in seen)) print pid "\t" pane[cur]
                    seen[cur] = 1
                    break
                }
                cur = parent[cur]
            }
        }
    }
' "$ps_file" > "$codex_file"

while IFS=$'\t' read -r pid pane; do
    tmux capture-pane -p -t "$pane" -S -100 2>/dev/null | awk -v PID="$pid" '
        # A progress line is not assistant output. Keep the last output block.
        /^[[:space:]]*• .*\(.*esc to interrupt\)/ { working = NR; block = 0; next }
        /^• / { out = $0; sub(/^• /, "", out); latest = NR; block = 1; next }
        block && /^  [[:alnum:]]/ { out = out " " $0; next }
        { block = 0 }
        /^[[:space:]]*› [0-9]+\./ { choice = NR }
        /Would you like to run the following command/ { approval = NR }
        /[Pp]ress enter to confirm|[Ee]nter to submit/ { confirm = NR }
        END {
            state = working > latest ? "busy" : "idle"
            reason = ""
            if (choice > latest && confirm > choice) {
                state = "waiting"
                reason = approval > latest ? "approval needed" : "input needed"
            }
            gsub(/\*\*|__|`/, "", out)
            gsub(/[[:space:]│[:cntrl:]]+/, " ", out)
            sub(/^ +/, "", out); sub(/ +$/, "", out)
            # This marker cannot be a Claude session ID.
            if (NR) printf "%s\t%s\t@codex\t-\t0\t%s\t%s\n", PID, state, reason, substr(out, 1, 120)
        }
    ' >> "$sessions_file"
done < "$codex_file"

awk -v PANES="$panes_file" -v PS="$ps_file" -v SF="$state_file" -v CF="$pane_file" -v PF="$preview_file" '
    # Higher number = more urgent. The most urgent session wins the window.
    function rank(s) { return s == "waiting" ? 3 : s == "busy" ? 2 : s == "idle" ? 1 : 0 }
    BEGIN {
        FS = "\t"
        while ((getline l < PANES) > 0) { split(l, p, "\t"); panewin[p[1]] = p[2] }
        # ps pads the pid on the left, so split on blanks.
        while ((getline l < PS) > 0) { split(l, p, " "); parent[p[1]] = p[2] }
    }
    {
        pid = $1; r = rank($2)
        # ps lists each live process, so a pid that is not in it is dead.
        if (r == 0 || !(pid in parent)) next
        # Walk the process ancestry until we land on a tmux pane.
        cur = pid
        for (depth = 0; cur > 1 && depth < 30; depth++) {
            if (cur in panewin) {
                wid = panewin[cur]
                print wid > CF
                if (!(wid in best) || r > best[wid] || (r == best[wid] && $5 + 0 > bchg[wid] + 0)) {
                    best[wid] = r; bchg[wid] = $5 + 0
                    row[wid] = wid "\t" $2 "\t" r "\t" $3 "\t" $4 "\t" $5 "\t" $6
                    preview[wid] = $7
                }
                break
            }
            cur = parent[cur]
        }
    }
    END {
        for (w in row) {
            print row[w] > SF
            if (preview[w] != "") print w "\t" preview[w] > PF
        }
    }
' "$sessions_file"

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
    # The session ID goes into two paths: the transcript and the cache. Accept
    # only a plain ID, so neither path can point outside its directory.
    case "$sid" in ''|*[!A-Za-z0-9-]*) continue ;; esac
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
    # Use the cache only if this user owns it and it is not a symlink.
    # Without a safe cache, the script reads each transcript every time.
    # Check for a symlink before mkdir and chmod, because both follow one.
    use_cache=0
    if [ ! -L "$CACHE_DIR" ] && (umask 077; mkdir -p "$CACHE_DIR") 2>/dev/null \
        && [ ! -L "$CACHE_DIR" ] && [ -O "$CACHE_DIR" ] && chmod 700 "$CACHE_DIR"; then
        use_cache=1
    fi
    for i in "${!transcripts[@]}"; do
        cache="$CACHE_DIR/${sids[$i]}"
        cached_stamp=""; out=""
        [ "$use_cache" -eq 1 ] && [ -f "$cache" ] && { read -r cached_stamp; read -r out; } < "$cache"
        if [ "$use_cache" -eq 0 ] || [ "$cached_stamp" != "${stamps[$i]:-}" ]; then
            out=$(tail -n 300 "${transcripts[$i]}" | jq -Rr "$LAST_OUTPUT_JQ" 2>/dev/null | tail -n 1)
            # Write a new file and move it into place, so a symlink at the
            # cache path is replaced and never followed. mktemp gives mode 0600.
            if [ "$use_cache" -eq 1 ] && tmp=$(mktemp "$CACHE_DIR/.tmp.XXXXXX" 2>/dev/null); then
                printf '%s\n%s\n' "${stamps[$i]:-}" "$out" > "$tmp" && mv -f "$tmp" "$cache"
            fi
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
        # The list shows the windows that need you first: waiting (red), then
        # idle (green), then busy (blue), then windows without an agent.
        if      (col == RED) r_rank[nrows] = 0
        else if (col == GRN) r_rank[nrows] = 1
        else if (col == BLU) r_rank[nrows] = 2
        else                 r_rank[nrows] = 3
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
        # Give the session colors in the order of recency. If the print order
        # gave them, a session could change color when a window changes state.
        for (i = 1; i <= nrows; i++) sess_color(r_sess[i])
        # One pass for each state. The input is in order of recency, and each
        # pass keeps that order, so the newest window of each state is first.
        for (rank = 0; rank <= 3; rank++)
        for (i = 1; i <= nrows; i++) {
          if (r_rank[i] != rank) continue
          # The session name is never cut, because the channel needs the full
          # name for the tmux target.
          line = r_dot[i] "  " sess_color(r_sess[i]) pad(r_sess[i], wsess) RST \
                 SEP IDX pad(r_idx[i], widx) RST \
                 SEP BLD pad(r_name[i], wname_w) RST
          # If the window has more than one agent pane, show the count. The
          # last output then comes from the pane that won the window.
          if (r_count[i] > 1) cnt = GRY r_count[i] "×" RST " "
          else                cnt = ""
          # If the agent waits for you, show the reason before the last output.
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
