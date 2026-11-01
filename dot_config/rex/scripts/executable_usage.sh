#!/bin/bash
# The status center of tmux prefix+u, drawn in a Rex float.
#
# This script sources the tmux script and replaces its one tmux seam,
# pane_root_pid. The views, the providers and the cache stay the same.
#
#   usage.sh --size PID   print "WxH" in cells for the pane whose first
#                         process is PID
#   usage.sh PID CWD      draw the view (the float runs this form)
#
# usage.lua reads PID from the "process" method of the terminal. The --size
# form runs in the environment of the Rex server, where PATH is only
# /usr/bin:/bin:/usr/sbin:/sbin. Thus the --size form must not need rex, jq,
# or a program from Homebrew.

# The sourced script reads SRC_PANE, SRC_PATH, PROVIDER and CONTEXT_TEXT.
# shellcheck disable=SC2034

set -u
USAGE_SCRIPT=${USAGE_SCRIPT:-$HOME/.tmux/scripts/claude-usage.sh}
# shellcheck source=/dev/null
source "$USAGE_SCRIPT"

# The tmux script asks tmux for #{pane_pid}. In Rex, the PID comes as an
# argument.
pane_root_pid() { printf '%s' "$REX_ROOT_PID"; }

if [ "${1:-}" = "--size" ]; then
  REX_ROOT_PID=${2:-}
  size_for rex
  exit
fi

REX_ROOT_PID=${1:-}
SRC_PANE=rex
SRC_PATH=${2:-}
PROVIDER=$(resolve_provider)
if declare -F context_section >/dev/null; then CONTEXT_TEXT=$(context_section); fi
view_main
