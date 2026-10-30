#!/usr/bin/env bash
# Opens a display-popup for a git tool (Neogit, Lazygit, bb-prs) sized from
# the shared git-popup-size.sh, so prefix+t/T/B and the prefix+e tuicr-review
# popup all stay in sync from one place.
#
# $1 — popup title
# $2 — pane current path (where the popup starts)
# $3.. — command to run in the popup
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/git-popup-size.sh"

title=${1:?title required}
cwd=${2:?pane path required}
shift 2

tmux display-popup -E -w "$POPUP_W" -h "$POPUP_H" -d "$cwd" -T " $title " -- bash -c "$*"
