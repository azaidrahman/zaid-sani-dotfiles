#!/bin/bash
# The status center of tmux prefix+u, drawn in a Rex float.
#
# This script sources the tmux script and replaces its one tmux seam,
# pane_root_pid. The views, the providers and the cache stay the same.
#
#   usage.sh --size PID   print "WxH" in cells for the pane whose first
#                         process is PID
#   usage.sh --refresh    fetch the Claude usage into the cache (the poller,
#                         usage-poller.lua, runs this form each minute). It
#                         prints one line for the log of the poller. It exits
#                         1 if the fetch gives no usage rows, for example when
#                         claude is not logged in.
#   usage.sh PID CWD      draw the view (the float runs this form)
#
# usage.lua reads PID from the "process" method of the terminal. The --size
# and --refresh forms run in the environment of the Rex server, where PATH is
# only /usr/bin:/bin:/usr/sbin:/sbin. Thus the --size form must not need rex,
# jq, or a program from Homebrew. The --refresh form adds Homebrew to PATH,
# because it runs claude.

# The sourced script reads SRC_PANE, SRC_PATH, PROVIDER and CONTEXT_TEXT.
# shellcheck disable=SC2034

set -u
USAGE_SCRIPT=${USAGE_SCRIPT:-$HOME/.tmux/scripts/claude-usage.sh}
# shellcheck source=/dev/null
source "$USAGE_SCRIPT"

# The poller refreshes the cache each minute. A cache younger than this is
# fresh, and the float draws it with no fetch. The margin covers a slow fetch.
USAGE_MAX_AGE=90

# All three forms must use the same cache, which is under TMPDIR. A process
# that has no TMPDIR uses the temporary directory that macOS gives the user.
TMPDIR=${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}

# The tmux script asks tmux for #{pane_pid}. In Rex, the PID comes as an
# argument.
pane_root_pid() { printf '%s' "$REX_ROOT_PID"; }

case "${1:-}" in
  --size)
    REX_ROOT_PID=${2:-}
    size_for rex
    ;;
  --refresh)
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    PROVIDER=claude
    blob=$(refresh_cache)
    rows=$(grep -c "^QUOTA$TAB" <<<"$blob")
    if (( rows > 0 )); then
      first=$(grep -m 1 "^QUOTA$TAB" <<<"$blob" | cut -f 2,3 | tr '\t' ' ')
      echo "$rows usage rows, ${first}%"
    else
      note=$(grep -m 1 "^NOTE$TAB" <<<"$blob" | cut -f 2-)
      echo "no usage rows: ${note:-the fetch printed nothing}" >&2
      exit 1
    fi
    ;;
  *)
    REX_ROOT_PID=${1:-}
    SRC_PANE=rex
    SRC_PATH=${2:-}
    PROVIDER=$(resolve_provider)
    if declare -F context_section >/dev/null; then CONTEXT_TEXT=$(context_section); fi
    view_main
    ;;
esac
