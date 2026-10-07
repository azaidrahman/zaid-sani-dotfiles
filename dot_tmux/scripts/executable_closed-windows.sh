#!/usr/bin/env bash
# Keep a log of the tmux windows that closed, and open one of them again.
# prefix+X shows the log (the tmux-closed tv channel). See keys.conf.
#
# A hook cannot read a closed window. When window-unlinked runs, the panes are
# gone, and the hook knows only the id and the name of the window. Thus the
# status line runs `snapshot` at each status-interval (5 seconds). It writes
# the panes of all windows to a file. When a window closes, `record` finds the
# panes of that window in the file and adds one entry to the log.
#
# `reopen` makes the window again in the same session, with the same name,
# directories and layout. If a pane ran Claude, the new pane resumes the same
# conversation. Other programs do not start again: the pane opens a shell in
# the same directory, and the preview shows what ran there.
#
# Commands:
#   snapshot                        write the pane file (from status-right)
#   record WINDOW_ID SESSION NAME   log a closed window (from window-unlinked)
#   list                            print the log for the picker, newest first
#   preview ID                      print the details of one entry
#   reopen ID                       open the window again, remove the entry
set -uo pipefail

STATE="${TMUX_CLOSED_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-closed-windows}"
PANES="$STATE/panes.tsv"
PREV="$STATE/panes.prev.tsv"
LOG="$STATE/closed.jsonl"
MAX_ENTRIES=100

# One line for each pane. The server pid comes first: window ids start again
# from @0 on a new server, so a row from an old server must not match.
# Keep the field numbers in sync with cw_record.
FMT=$(printf '%s\t' '#{pid}' '#{window_id}' '#{session_name}' '#{window_index}' \
	'#{window_name}' '#{window_layout}' '#{pane_index}' '#{pane_current_path}' \
	'#{pane_current_command}' '#{pane_title}' '#{@claude_transcript}' '#{@zen_owned}')
FMT=${FMT%$'\t'}

# cw_lock / cw_unlock — a lock for changes to the log. A closed session fires
# window-unlinked once for each window, and the hooks run at the same time.
cw_lock() {
	local _
	for _ in $(seq 1 50); do
		mkdir "$STATE/.lock" 2>/dev/null && return 0
		sleep 0.05
	done
	# A lock that is older than the wait is stale. Take it.
	rmdir "$STATE/.lock" 2>/dev/null
	mkdir "$STATE/.lock" 2>/dev/null
	return 0
}
cw_unlock() { rmdir "$STATE/.lock" 2>/dev/null || true; }

cw_snapshot() {
	mkdir -p "$STATE" || return 0
	local tmp="$STATE/.panes.$$"
	if ! tmux list-panes -a -F "$FMT" >"$tmp" 2>/dev/null; then
		rm -f "$tmp"
		return 0
	fi
	if cmp -s "$tmp" "$PANES"; then
		rm -f "$tmp"
		return 0
	fi
	# Keep the last file too. A snapshot can run after a window closes and
	# before its hook reads the file. Then only the last file has its panes.
	[ -f "$PANES" ] && mv -f "$PANES" "$PREV"
	mv -f "$tmp" "$PANES"
}

cw_record() {
	local wid="${1:?window id required}" sess="${2:-}" name="${3:-}"
	mkdir -p "$STATE" || return 0

	# A window that moves to another session also fires window-unlinked. It
	# still exists, so it did not close.
	tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -qxF -- "$wid" && return 0

	local spid rows=""
	spid=$(tmux display-message -p '#{pid}' 2>/dev/null) || return 0
	local f
	for f in "$PANES" "$PREV"; do
		[ -f "$f" ] || continue
		rows=$(awk -F'\t' -v p="$spid" -v w="$wid" '$1 == p && $2 == w' "$f")
		[ -n "$rows" ] && break
	done

	# No rows: the window closed less than one snapshot after it opened, for
	# example a placeholder window that a script made and killed. Nobody can
	# forget a window like that, so do not log it.
	[ -n "$rows" ] || return 0

	local now entry
	now=$(date +%s)
	entry=$(printf '%s\n' "$rows" | jq -Rnc \
		--arg id "$now-${wid#@}" --argjson time "$now" --arg sess "$sess" --arg name "$name" '
		[inputs | split("\t") | {
			session: .[2], index: .[3], name: .[4], layout: .[5],
			pane: (.[6] | tonumber), cwd: .[7], cmd: .[8], title: .[9],
			transcript: .[10], zen: .[11]
		}] | unique_by(.pane) as $p
		| if any($p[]; .zen == "1") then empty else
			{
				id: $id, time: $time,
				session: (if $sess != "" then $sess else $p[0].session end),
				name: (if $name != "" then $name else $p[0].name end),
				index: $p[0].index, layout: $p[0].layout,
				panes: [$p[] | {cwd, cmd, title, transcript}]
			}
		end') || return 0
	[ -n "$entry" ] || return 0

	cw_lock
	printf '%s\n' "$entry" >>"$LOG"
	if [ "$(wc -l <"$LOG")" -gt "$MAX_ENTRIES" ]; then
		tail -n "$MAX_ENTRIES" "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
	fi
	cw_unlock
}

# cw_list — one line for each entry, newest first: the id, a tab, then the
# text that the picker shows.
cw_list() {
	if [ ! -s "$LOG" ]; then
		printf -- '-\tNo closed windows yet\n'
		return 0
	fi
	jq -rs --argjson now "$(date +%s)" --arg home "$HOME" '
		def age: ($now - .) as $s
			| if $s < 60 then "\($s)s"
			elif $s < 3600 then "\($s / 60 | floor)m"
			elif $s < 86400 then "\($s / 3600 | floor)h"
			else "\($s / 86400 | floor)d" end;
		def tilde: if startswith($home) then "~" + ltrimstr($home) else . end;
		reverse[]
		| [
			.id, (.time | age), "\(.session):\(.index)", .name,
			((.panes[0].cwd // "") | tilde),
			([.panes[] | select(.transcript != "") | .title] | first // "")
		] | join("\u001f")' "$LOG" |
		while IFS=$'\x1f' read -r id age where name dir title; do
			printf '%s\t%-4s %-18s %-22s %s%s\n' "$id" "$age" "$where" "$name" "$dir" \
				"${title:+  ($title)}"
		done
}

cw_preview() {
	local id="${1:-}"
	[ -s "$LOG" ] || return 0
	jq -r --arg id "$id" --arg home "$HOME" '
		def tilde: if startswith($home) then "~" + ltrimstr($home) else . end;
		select(.id == $id)
		| "Window   \(.name)",
		  "Session  \(.session) (window \(.index))",
		  "Closed   \(.time | localtime | strftime("%Y-%m-%d %H:%M:%S"))",
		  "",
		  (.panes | to_entries[] |
			"Pane \(.key)",
			"  dir      \(.value.cwd | tilde)",
			"  command  \(.value.cmd)",
			(if .value.transcript != "" then
				"  claude   \(.value.title)",
				"  session  \(.value.transcript | split("/") | last | rtrimstr(".jsonl"))"
			else empty end),
			""),
		  "Enter: open this window again"' "$LOG"
}

# cw_resume_cmd CMD TRANSCRIPT — print the command that brings back the
# program of a pane, or nothing. Only Claude comes back. A pane that runs a
# shell now ran Claude before, so its transcript is old: start nothing.
cw_resume_cmd() {
	local cmd="$1" transcript="$2"
	[ -n "$transcript" ] || return 0
	case "${cmd#-}" in zsh | bash | fish | sh | dash | ksh | tcsh) return 0 ;; esac
	# A transcript that is not on disk is a session with no messages.
	if [ -f "$transcript" ]; then
		printf 'claude --resume %s\n' "$(basename "$transcript" .jsonl)"
	else
		printf 'claude\n'
	fi
}

cw_reopen() {
	local id="${1:-}" entry
	[ -s "$LOG" ] || return 0
	entry=$(jq -c --arg id "$id" 'select(.id == $id)' "$LOG" | tail -n 1)
	if [ -z "$entry" ]; then
		tmux display-message "closed window not found: $id"
		return 0
	fi

	local sess name layout
	sess=$(jq -r '.session' <<<"$entry")
	name=$(jq -r '.name' <<<"$entry")
	layout=$(jq -r '.layout' <<<"$entry")

	local wid="" last="" pane cwd cmd transcript run
	while IFS=$'\x1f' read -r cwd cmd transcript; do
		[ -d "$cwd" ] || cwd=$HOME
		if [ -z "$wid" ]; then
			if tmux has-session -t "=$sess" 2>/dev/null; then
				pane=$(tmux new-window -d -t "=$sess:" -n "$name" -c "$cwd" -P -F '#{pane_id}')
			else
				# The session closed with its last window. Make it again.
				pane=$(tmux new-session -d -s "$sess" -n "$name" -c "$cwd" -P -F '#{pane_id}' 2>/dev/null ||
					tmux new-window -d -n "$name" -c "$cwd" -P -F '#{pane_id}')
			fi
			[ -n "$pane" ] || return 1
			wid=$(tmux display-message -p -t "$pane" '#{window_id}')
		else
			# Split the last pane, so the panes keep their order. The tiled
			# layout makes space for the next split.
			pane=$(tmux split-window -d -t "$last" -c "$cwd" -P -F '#{pane_id}') || break
			tmux select-layout -t "$wid" tiled >/dev/null 2>&1
		fi
		last=$pane
		run=$(cw_resume_cmd "$cmd" "$transcript")
		if [ -n "$run" ]; then
			tmux send-keys -t "$pane" -l "$run"
			tmux send-keys -t "$pane" Enter
		fi
	done < <(jq -r '.panes[] | [.cwd, .cmd, .transcript] | join("\u001f")' <<<"$entry")
	[ -n "$wid" ] || return 1

	# The layout fails if the window has a different size. Then tiled stays.
	[ -n "$layout" ] && tmux select-layout -t "$wid" "$layout" >/dev/null 2>&1

	cw_lock
	jq -c --arg id "$id" 'select(.id != $id)' "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
	cw_unlock

	tmux switch-client -t "$wid" 2>/dev/null || true
	tmux select-window -t "$wid"
}

# Run only when executed, so a test can source the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	case "${1:-}" in
	snapshot) cw_snapshot ;;
	record) shift && cw_record "$@" ;;
	list) cw_list ;;
	preview) shift && cw_preview "$@" ;;
	reopen) shift && cw_reopen "$@" ;;
	*)
		echo "usage: closed-windows.sh snapshot|record|list|preview|reopen" >&2
		exit 2
		;;
	esac
fi
