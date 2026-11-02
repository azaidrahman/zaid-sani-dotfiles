#!/usr/bin/env bash
# The rex-tabs tv channel: the tab picker of tab_picker.lua. This is the Rex
# copy of the tmux-windows channel (~/.tmux/scripts/tv-tmux-windows.sh).
#
# Each row is one tab:
#   ●  <session> │ <key> │ <tab> │ <last agent output>
# The dot shows the most urgent agent in the tab: red waits for you, green is
# idle, blue works, grey has no agent. The rows that wait for you come first.
# The key is the last 8 characters of the window id. preview and select take
# it. It has only hex digits, so the channel can use it without quotes.
#
# tab-picker.lua collects the data in one `rex do` call. Each list also
# writes a map from each key to its tab, so preview and select need no
# search. The last output of a Claude pane comes from its transcript, with a
# cache by the modification time and the size of the transcript.
#
# Commands:
#   open                    make the font of this pane smaller, then start
#                           the channel. tab_picker.lua runs it in the float.
#   list active|hold|other  the rows of one group
#                           active: tabs of a session that is not held
#                           hold:   tabs of a held session (hold.lua)
#                           other:  tabs of a utility session
#   preview KEY             the screen of the pane of the tab
#   select KEY              ask the Rex app to show the tab. If
#                           REX_TABS_CLIENT holds a client id, ask that app.
set -uo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DATA="$DIR/tab-picker.lua"
HOLD_LIST="${REX_HOLD_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/rex-hold}/held"
SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
# The cache holds text from the transcripts, so it must be private. It is
# under the home directory, not in a shared temporary directory.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rex-tab-picker"
MAP="$CACHE_DIR/map"
# Utility sessions. They are not work, so they get their own group.
UTIL_SESSIONS="mobile quickterminal"
# The float uses a smaller font than the other panes. One step is 1 point,
# so the default size of 20 becomes 14.
FONT_STEPS=6

# private_cache — make the cache directory, and fail if it is not safe: a
# symlink, or a directory of another user. Check for a symlink before mkdir
# and chmod, because both follow one.
private_cache() {
	[ ! -L "$CACHE_DIR" ] && (umask 077; mkdir -p "$CACHE_DIR") 2>/dev/null &&
		[ ! -L "$CACHE_DIR" ] && [ -O "$CACHE_DIR" ] && chmod 700 "$CACHE_DIR"
}

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

# last_output SESSION_ID CWD CACHE_OK — print the last output of a Claude
# session, from the cache if the transcript did not change.
last_output() {
	local sid=$1 cwd=$2 cache_ok=$3 t stamp cache cached_stamp="" out="" tmp
	# The session id goes into two paths. Accept only a plain id, so neither
	# path can point outside its directory.
	case "$sid" in '' | *[!A-Za-z0-9-]*) return 0 ;; esac
	# Claude names the project directory after the cwd, with each character
	# that is not alphanumeric changed to `-`.
	t="$PROJECTS_DIR/${cwd//[^A-Za-z0-9]/-}/$sid.jsonl"
	[ -f "$t" ] || return 0
	stamp=$(stat -f '%m.%z' "$t" 2>/dev/null || stat -c '%Y.%s' "$t" 2>/dev/null)
	cache="$CACHE_DIR/$sid"
	if [ "$cache_ok" = 1 ] && [ -f "$cache" ]; then
		{ read -r cached_stamp; read -r out; } <"$cache"
	fi
	if [ "$cache_ok" != 1 ] || [ "$cached_stamp" != "$stamp" ]; then
		out=$(tail -n 300 "$t" | jq -Rr "$LAST_OUTPUT_JQ" 2>/dev/null | tail -n 1)
		# Write a new file and move it into place, so a symlink at the cache
		# path is replaced and never followed. mktemp gives mode 0600.
		if [ "$cache_ok" = 1 ] && tmp=$(mktemp "$CACHE_DIR/.tmp.XXXXXX" 2>/dev/null); then
			printf '%s\n%s\n' "$stamp" "$out" >"$tmp" && mv -f "$tmp" "$cache"
		fi
	fi
	printf '%s' "$out"
}

tp_list() {
	local mode=${1:-active} data cache_ok=0 rows tmp
	data=$(rex --autostart=false do "$DATA" hold_list="$HOLD_LIST" \
		claude_sessions="$SESSIONS_DIR" 2>/dev/null) || data='{}'
	private_cache && cache_ok=1

	if [ "$cache_ok" = 1 ] && tmp=$(mktemp "$CACHE_DIR/.map.XXXXXX" 2>/dev/null); then
		jq -r '(.tabs | arrays)[] | [.key, .session_id, .window_id, .block_id] | @tsv' \
			<<<"$data" >"$tmp" 2>/dev/null && mv -f "$tmp" "$MAP"
	fi

	# One line per tab of this group, in the order of the list:
	# rank, session, key, tab, state, message, agents, claude id, claude cwd.
	# The separator is \x1f, not a tab: `read` joins two tabs into one, and
	# an empty field then moves the fields after it.
	rows=$(jq -r --arg mode "$mode" --arg util "$UTIL_SESSIONS" '
		def clean: tostring | gsub("[\\t\\n\\r│]"; " ");
		($util | split(" ")) as $u
		| (.tabs | arrays)[]
		| (if (.session as $s | $u | index($s)) then "other"
		   elif .held then "hold" else "active" end) as $group
		| select($group == $mode)
		| [ ({blocked: 0, error: 0, idle: 1, done: 1, working: 2}[.state // ""] // 3),
		    (.session | clean), .key, (.label | clean), (.state // ""),
		    ((.msg // "") | clean), .agents, (.claude_id // ""), (.claude_cwd // "") ]
		| map(tostring | gsub("\u001f"; " ")) | join("\u001f")' <<<"$data" 2>/dev/null)

	local rank sess key name state msg agents cid ccwd out
	while IFS=$'\x1f' read -r rank sess key name state msg agents cid ccwd; do
		[ -n "$key" ] || continue
		out=""
		[ -n "$cid" ] && out=$(last_output "$cid" "$ccwd" "$cache_ok")
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$rank" "$sess" "$key" "$name" "$state" "$msg" "$agents" "$out"
	done <<<"$rows" | awk -F'\t' -v MODE="$mode" '
		# A color per session name, so the tabs of one session stand out. The
		# hash of the name picks the start slot, so a session keeps its color.
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
		function clip(s, w) { return (length(s) > w) ? substr(s, 1, w - 1) "…" : s }
		function pad(s, w) { return s sprintf("%" (w - length(s)) "s", "") }
		BEGIN {
			for (i = 32; i < 127; i++) ord[sprintf("%c", i)] = i
			npal = split("81 213 221 141 114 209 75 176 186 116", palette, " ")
			# Fixed 24-bit colors for the dots. The blue of a terminal theme
			# is too dark on the selection background of tv.
			RED = "\033[1;38;2;255;85;85m"; BLU = "\033[1;38;2;96;165;250m"
			GRN = "\033[1;38;2;74;222;128m"; GRY = "\033[90m"
			BLD = "\033[1m"; PRV = "\033[2;3m"; RST = "\033[0m"
			SEP = " " GRY "│" RST " "
			MAXNAME = 34
		}
		{
			n++
			r_rank[n] = $1; r_sess[n] = $2; r_key[n] = $3
			r_name[n] = clip($4, MAXNAME); r_state[n] = $5; r_msg[n] = $6
			r_agents[n] = $7 + 0; r_out[n] = $8
			if (length($2) > wsess) wsess = length($2)
			if (length(r_name[n]) > wname) wname = length(r_name[n])
		}
		END {
			# Give the colors in list order, so a color does not change when
			# a tab changes its state.
			for (i = 1; i <= n; i++) sess_color(r_sess[i])
			for (rank = 0; rank <= 3; rank++)
			for (i = 1; i <= n; i++) {
				if (r_rank[i] != rank) continue
				s = r_state[i]
				col = (s == "blocked" || s == "error") ? RED : (s == "working") ? BLU \
					: (s == "idle" || s == "done") ? GRN : GRY
				line = col "●" RST "  " sess_color(r_sess[i]) pad(r_sess[i], wsess) RST \
					SEP GRY r_key[i] RST SEP BLD pad(r_name[i], wname) RST
				# If the tab has more than one agent pane, show the count.
				cnt = (r_agents[i] > 1) ? GRY r_agents[i] "×" RST " " : ""
				# If the agent waits for you, show why before the last output.
				wait = (col == RED && r_msg[i] != "") ? RED "◆ " r_msg[i] RST GRY " · " RST : ""
				prev = (r_out[i] != "") ? r_out[i] : (col == BLU ? r_msg[i] : "")
				if (cnt != "" || wait != "" || prev != "") line = line SEP cnt wait PRV prev RST
				print line
			}
			if (n == 0) {
				if (MODE == "hold") msg = "no sessions on hold"
				else if (MODE == "other") msg = "no other sessions"
				else msg = "no working sessions"
				printf "%s  \033[2;37m%s%s\n", GRY "●" RST, msg, RST
			}
		}'
}

# tp_lookup KEY — print the session id, the window id and the block id of a
# tab, from the map of the last list.
tp_lookup() {
	local key=${1:-}
	case "$key" in '' | *[!0-9a-f]*) return 1 ;; esac
	[ -f "$MAP" ] || return 1
	awk -F'\t' -v k="$key" '$1 == k { print $2 "\t" $3 "\t" $4; found = 1; exit }
		END { exit !found }' "$MAP"
}

# tv_safe — change the screen of a pane so that tv shows it as it is.
#
# A capture in the vt format holds only the screen, with its colors. It
# moves the cursor right (CSI n C) over blank cells. tv shows colors, but
# not cursor movements, so each movement becomes spaces.
#
# tv shows each character above U+0700 that is not in its list as the NUL
# symbol. The list has box drawing, arrows, shapes and Nerd Font glyphs, but
# not the Dingbats and the Miscellaneous Symbols. Claude draws its spinner
# with Dingbats (✻ ✳ ✢), so those become "*", ✓ becomes √ and ✗ becomes ×.
tv_safe() {
	perl -CSD -pe '
		s/\e\[(\d*)C/" " x ($1 || 1)/ge;
		tr/\x{2713}\x{2714}\x{2717}\x{2718}/\x{221A}\x{221A}\x{00D7}\x{00D7}/;
		s/[\x{2600}-\x{262F}\x{2631}-\x{2664}\x{2666}-\x{26A0}\x{26A2}-\x{26FF}\x{2700}-\x{276B}\x{2772}-\x{27BF}]/*/g;
	'
}

tp_preview() {
	local sid wid bid
	printf '\033[1;38;2;96;165;250m●\033[0m working   \033[1;38;2;255;85;85m●\033[0m waiting   \033[1;38;2;74;222;128m●\033[0m idle\n\n'
	if ! IFS=$'\t' read -r sid wid bid < <(tp_lookup "${1:-}"); then
		echo 'No preview available'
		return 0
	fi
	rex --autostart=false capture -s "$sid" -b "$bid" --trim --format=vt 2>/dev/null | tv_safe ||
		echo 'No preview available'
}

# tp_open — the app keeps a font size for each pane. A font action from an
# action of init.lua acts on the pane where the action started, not on the
# float. Thus the float asks for the change itself, with its own pane id. The
# size goes away when the float closes.
tp_open() {
	local _
	if [ -n "${REX_SESSION:-}" ] && [ -n "${REX_BLOCK:-}" ]; then
		for _ in $(seq 1 "$FONT_STEPS"); do
			rex --autostart=false ${REX_TABS_CLIENT:+-C "$REX_TABS_CLIENT"} \
				do client.font.decrease -s "$REX_SESSION" -b "$REX_BLOCK" >/dev/null 2>&1 || break
		done
	fi
	exec tv rex-tabs
}

tp_select() {
	local sid wid bid
	IFS=$'\t' read -r sid wid bid < <(tp_lookup "${1:-}") || return 0
	rex --autostart=false ${REX_TABS_CLIENT:+-C "$REX_TABS_CLIENT"} \
		do session.select session_id="$sid" window_id="$wid"
}

# Run only when executed, so a test can source the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	case "${1:-}" in
	open) tp_open ;;
	list) shift && tp_list "$@" ;;
	preview) shift && tp_preview "$@" ;;
	select) shift && tp_select "$@" ;;
	*)
		echo "usage: tab-picker.sh open | list active|hold|other | preview KEY | select KEY" >&2
		exit 2
		;;
	esac
fi
