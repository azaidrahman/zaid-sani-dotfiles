#!/usr/bin/env bash
# Open a Rex tab or session that closed. This is the Rex copy of tmux prefix+X
# (~/.tmux/scripts/closed-windows.sh).
#
# closed-tabs-watcher.lua writes the log. Each entry is one tab that closed,
# or one session that was destroyed with all of its tabs. The rex-closed tv
# channel shows the log, and Enter runs `reopen`.
#
# `reopen` makes the tab again with the same label, panes, splits and
# directories, at the same position. A tab goes back to its session. If that
# session is gone, the tab goes to a session with the same label, or to a new
# session. A session entry makes a new session with all of its tabs. If a
# pane ran Claude, the new pane resumes the same conversation. Other programs
# do not start again: the pane opens a shell in the same directory.
#
# If REX_CLOSED_CLIENT holds a client id, the Rex app of that client then
# shows the tab.
#
# Commands:
#   list          print the log for the picker, newest first
#   preview ID    print the details of one entry
#   reopen ID     open the entry again, and remove it from the log
set -uo pipefail

STATE="${REX_CLOSED_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/rex-closed-tabs}"
LOG="$STATE/closed.jsonl"

# ct_lock / ct_unlock — the same lock that the watcher uses for the log.
ct_lock() {
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
ct_unlock() { rmdir "$STATE/.lock" 2>/dev/null || true; }

# ct_list — one line for each entry, newest first: the id, a tab, then the
# text that the picker shows.
ct_list() {
	if [ ! -s "$LOG" ]; then
		printf -- '-\tNo closed tabs yet\n'
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
		| .windows[0] as $w
		| [
			.id, (.time | age),
			(if .kind == "session" then "\(.session) [session]" else "\(.session):\($w.index)" end),
			(if .kind == "session" then "\(.windows | length) tabs" else $w.label end),
			(($w.panes[0].cwd // "") | tilde),
			([.windows[].panes[] | select(.claude_id != null) | .claude_name // "claude"] | first // "")
		] | join("\u001f")' "$LOG" |
		while IFS=$'\x1f' read -r id age where name dir claude; do
			printf '%s\t%-4s %-24s %-22s %s%s\n' "$id" "$age" "$where" "$name" "$dir" \
				"${claude:+  ($claude)}"
		done
}

ct_preview() {
	local id="${1:-}"
	[ -s "$LOG" ] || return 0
	jq -r --arg id "$id" --arg home "$HOME" '
		def tilde: if startswith($home) then "~" + ltrimstr($home) else . end;
		select(.id == $id)
		| (if .kind == "session" then "Session  \(.session) (\(.windows | length) tabs)"
			else "Tab      \(.windows[0].label)", "Session  \(.session) (tab \(.windows[0].index))" end),
		  "Closed   \(.time | localtime | strftime("%Y-%m-%d %H:%M:%S"))",
		  "",
		  (.windows[] |
			(if (.panes | length) > 0 then "\(.label)" else empty end),
			(.panes | to_entries[] |
				"  Pane \(.key + 1)",
				"    dir      \((.value.cwd // "") | tilde)",
				"    command  \(.value.cmd // "")",
				(if .value.claude_id then
					"    claude   \(.value.claude_name // "")",
					"    session  \(.value.claude_id)"
				else empty end)),
			""),
		  "Enter: open this \(if .kind == "session" then "session" else "tab" end) again"' "$LOG"
}

# ct_session_by_label LABEL — print the id of a session with this label.
ct_session_by_label() {
	rex api call session.list '{}' 2>/dev/null |
		jq -r --arg l "$1" 'first(.sessions[] | select(.label == $l) | .session_id) // empty'
}

# ct_window_at SESSION INDEX — print the id of the window at this position.
ct_window_at() {
	rex api call -s "$1" session.view '{}' 2>/dev/null |
		jq -r --argjson i "$2" '.windows[$i - 1].window_id // empty'
}

ct_reopen() {
	local id="${1:-}" entry
	[ -s "$LOG" ] || return 0
	entry=$(jq -c --arg id "$id" 'select(.id == $id)' "$LOG" | tail -n 1)
	if [ -z "$entry" ]; then
		echo "closed tab not found: $id" >&2
		return 1
	fi

	local kind sid label out wid=""
	kind=$(jq -r '.kind' <<<"$entry")
	sid=$(jq -r '.session_id' <<<"$entry")
	label=$(jq -r '.session' <<<"$entry")

	# A tab goes back to its own session, or to a session with the same label.
	if [ "$kind" = tab ]; then
		rex api call -s "$sid" session.view '{}' >/dev/null 2>&1 || sid=$(ct_session_by_label "$label")
	else
		sid=""
	fi

	if [ -n "$sid" ]; then
		out=$(jq -c '.windows[0] | {window_label: .label, layout, focus: true}' <<<"$entry" |
			rex api call -s "$sid" session.new_window -) || return 1
		wid=$(jq -r '.window_id' <<<"$out")
		# Put the tab back at its position. The window that is there now
		# moves one step to the right.
		local index before
		index=$(jq -r '.windows[0].index' <<<"$entry")
		before=$(ct_window_at "$sid" "$index")
		if [ -n "$before" ] && [ "$before" != "$wid" ]; then
			jq -nc --arg w "$wid" --arg b "$before" '{window_id: $w, before_window_id: $b}' |
				rex api call -s "$sid" session.move_window - >/dev/null 2>&1
		fi
	else
		# The session is gone. Make it again with all the tabs of the entry.
		out=$(jq -c '{label: .session, initial_windows: [.windows[] | {window_label: .label, layout}]}' <<<"$entry" |
			rex api call session.create -) || return 1
		sid=$(jq -r '.session_id' <<<"$out")
		wid=$(rex api call -s "$sid" session.view '{}' | jq -r '.active_window_id // empty')
	fi

	ct_lock
	jq -c --arg id "$id" 'select(.id != $id)' "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
	ct_unlock

	if [ -n "${REX_CLOSED_CLIENT:-}" ]; then
		rex -C "$REX_CLOSED_CLIENT" do session.select session_id="$sid" ${wid:+window_id="$wid"} >/dev/null 2>&1 || true
	fi
	printf '%s %s\n' "$sid" "$wid"
}

# Run only when executed, so a test can source the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	case "${1:-}" in
	list) ct_list ;;
	preview) shift && ct_preview "$@" ;;
	reopen) shift && ct_reopen "$@" ;;
	*)
		echo "usage: closed-tabs.sh list|preview ID|reopen ID" >&2
		exit 2
		;;
	esac
fi
