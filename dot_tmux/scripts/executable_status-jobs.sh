#!/usr/bin/env bash
# Add the background jobs to status-right. hooks.conf runs this script last,
# after the theme has written status-right.
#
# tmux runs each #() job in the status line at each status-interval. Two
# scripts use this as a timer:
#
#   continuum_save.sh     tmux-continuum autosave (see plugins.conf). The
#                         plugin adds this job itself when TPM loads it. But
#                         tokyo-night loads after it and writes a new
#                         status-right, so the job was lost and the autosave
#                         stopped.
#   closed-windows.sh     the pane snapshot for the log of closed windows
#                         (prefix+X).
#
# Each job prints nothing, so the status line does not change. The script
# adds a job only if status-right does not have it, so a config reload does
# not add a second copy.
set -u

# add_job MATCH COMMAND — add #(COMMAND) to status-right if no job in it
# contains MATCH.
add_job() {
	case "$(tmux show-options -gv status-right)" in
	*"$1"*) ;;
	*) tmux set-option -ga status-right "#($2)" ;;
	esac
}

continuum="$HOME/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh"
[ -x "$continuum" ] && add_job continuum_save.sh "$continuum"
add_job "closed-windows.sh snapshot" "$HOME/.tmux/scripts/closed-windows.sh snapshot"
