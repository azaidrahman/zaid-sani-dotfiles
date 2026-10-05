#!/usr/bin/env bash
# Restart the Claude Code session that runs in a tmux pane, and resume the same
# conversation. Use it after a Claude Code update: the new process loads the new
# version. Triggered by prefix+A (see keys.conf).
#
# Steps:
#   1. Find the claude process on the tty of the pane. If there is none, show
#      an error popup and stop.
#   2. Read the session id from @claude_transcript. tag-pane-session.sh sets
#      this pane option on each turn, so it names the exact session of this
#      pane, also when other Claude panes use the same directory.
#   3. Stop claude with SIGTERM (SIGKILL after 5 seconds), then type the resume
#      command into the shell that started it.
#
# The new command uses the same launcher as before. If the old process had
# ANTHROPIC_BASE_URL in its environment, it came from `cv` (the LiteLLM proxy),
# so the new one starts with `cv` too. Only a small set of flags carries over
# (see rc_launch_cmd): ps prints the old command line without its quotes, so a
# prompt argument and a flag value cannot be told apart in general.
#
# Args: 1=pane id  2=pane tty  3=client name (for the popup)

RC_TIMEOUT_TENTHS="${RC_TIMEOUT_TENTHS:-50}"

# rc_find_claude — read "pid ppid args..." lines (ps output) on stdin and print
# the pid of the outermost claude process. The native install runs as `claude`,
# and an npm install runs as `node .../claude`, so check the first two words.
rc_find_claude() {
	awk '
	function base(p) { sub(/.*\//, "", p); return p }
	{
		if (base($3) == "claude" || ($4 != "" && base($4) == "claude")) {
			pid[NR] = $1; ppid[NR] = $2; is[$1] = 1
		}
	}
	END {
		for (i in pid) if (!(ppid[i] in is)) { print pid[i]; exit }
	}'
}

# rc_launch_cmd SID USE_CV ARGS... — print the command that resumes SID. ARGS
# are the words of the old command line, after the program name. USE_CV is 1
# when the old process came from `cv`.
rc_launch_cmd() {
	local sid="$1" use_cv="$2"
	shift 2
	local keep=() prev=""
	for a in "$@"; do
		case "$prev" in
		--model | --permission-mode)
			keep+=("$prev" "$a")
			prev=""
			continue
			;;
		esac
		prev=""
		case "$a" in
		--dangerously-skip-permissions) keep+=("$a") ;;
		# cv adds this flag itself.
		--allow-dangerously-skip-permissions) [ "$use_cv" = 1 ] || keep+=("$a") ;;
		--model | --permission-mode) prev="$a" ;;
		--model=* | --permission-mode=*) keep+=("$a") ;;
		esac
	done
	local cmd="claude"
	[ "$use_cv" = 1 ] && cmd="cv"
	[ "${#keep[@]}" -gt 0 ] && cmd="$cmd ${keep[*]}"
	[ -n "$sid" ] && cmd="$cmd --resume $sid"
	printf '%s\n' "$cmd"
}

# rc_fail MSG — show MSG in a small popup on the client, then exit. Without a
# client (for example a run from a test), show it in the status line.
rc_fail() {
	local msg="$1" width
	width=$((${#msg} + 6))
	[ "$width" -lt 40 ] && width=40
	if [ -n "${CLIENT:-}" ]; then
		tmux display-popup -c "$CLIENT" -w "$width" -h 6 -T ' Restart Claude ' \
			-e "RC_MSG=$msg" -E \
			"bash -c 'printf \"\\n %s\\n\\n press any key\" \"\$RC_MSG\"; read -rsn1'"
	else
		tmux display-message -t "$PANE" "restart claude: $msg"
	fi
	exit 0
}

rc_main() {
	set -euo pipefail
	PANE="${1:?pane id required}"
	local tty="${2:?pane tty required}"
	CLIENT="${3:-}"
	tty="${tty#/dev/}"

	# 1. Find claude.
	local pid
	pid=$(ps -t "$tty" -o pid=,ppid=,args= 2>/dev/null | rc_find_claude || true)
	[ -n "$pid" ] || rc_fail "This pane is not running a Claude session."

	# 2. Find the session. A tagged transcript that is not on disk yet is a
	# session with no messages, so a fresh start loses nothing.
	local transcript sid=""
	transcript=$(tmux show-options -pqv -t "$PANE" @claude_transcript 2>/dev/null || true)
	[ -n "$transcript" ] || rc_fail "No session id on this pane. The SessionStart hook did not tag it."
	[ -f "$transcript" ] && sid=$(basename "$transcript" .jsonl)

	# Read the environment into a variable first: with pipefail, `grep -q`
	# can make ps fail with SIGPIPE.
	local use_cv=0 env args cmd words=()
	env=$(ps eww -p "$pid" -o command= 2>/dev/null || true)
	case "$env" in *" ANTHROPIC_BASE_URL="*) use_cv=1 ;; esac
	args=$(ps -p "$pid" -o args= 2>/dev/null || true)
	[ -n "$args" ] || rc_fail "Claude stopped before the restart (pid $pid)."
	# Drop the program name: `claude` or `node .../claude`.
	read -r -a words <<<"$args"
	case "${words[0]##*/}" in claude) words=("${words[@]:1}") ;; *) words=("${words[@]:2}") ;; esac
	cmd=$(rc_launch_cmd "$sid" "$use_cv" ${words[@]+"${words[@]}"})

	# 3. Restart. If claude is the first process of the pane, no shell waits
	# below it, so replace the pane process. respawn-pane keeps the cwd. cv is
	# a zsh function, so only an interactive zsh can find it.
	local pane_pid
	pane_pid=$(tmux display-message -p -t "$PANE" '#{pane_pid}')
	if [ "$pid" = "$pane_pid" ]; then
		[ "$use_cv" = 1 ] && cmd="zsh -ic '$cmd'"
		tmux respawn-pane -k -t "$PANE" "$cmd"
	else
		kill -TERM "$pid" 2>/dev/null || true
		local i=0
		while kill -0 "$pid" 2>/dev/null; do
			i=$((i + 1))
			if [ "$i" -ge "$RC_TIMEOUT_TENTHS" ]; then
				kill -KILL "$pid" 2>/dev/null || true
				sleep 0.3
				break
			fi
			sleep 0.1
		done
		kill -0 "$pid" 2>/dev/null && rc_fail "Claude did not stop (pid $pid)."
		tmux send-keys -t "$PANE" -l "$cmd"
		tmux send-keys -t "$PANE" Enter
	fi
	tmux display-message -t "$PANE" "restarted claude${sid:+ ${sid: -5}}"
}

# Run only when executed, so a test can source the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	rc_main "$@"
fi
