#!/usr/bin/env bash
# Cycle prefix+[ / prefix+] through the same filtered window set as the
# `tmux-windows` tv channel (prefix+f), in a stable spatial order.
#   $1 = direction: next | prev
#   $2 = current target as session:window_index (passed by the binding)
#
# Set CYCLE_DRY_RUN=1 to print the target instead of switching to it. The tests
# use this, because a real switch needs an attached client.
set -u
dir="${1:-next}"; cur="${2:-}"

# Same exclusions as tv-tmux-windows.sh, plus held sessions: a session marked
# `[HOLD] ` is blocked on something, so rotation must step over it.
# Stable order: session, then window idx.
mapfile -t t < <(
  tmux list-windows -a -F '#{session_name}	#{window_index}	#{window_name}' \
    | awk -F'\t' '$1=="mobile"||$1=="quickterminal"{next} $3~/^md:/{next} index($1,"[HOLD] ")==1{next} {print $1":"$2}' \
    | sort -t: -k1,1 -k2,2n
)
n=${#t[@]}; [ "$n" -eq 0 ] && exit 0

i=0; for x in "${t[@]}"; do [ "$x" = "$cur" ] && break; i=$((i+1)); done
[ "$i" -ge "$n" ] && i=0
if [ "$dir" = prev ]; then i=$(((i-1+n)%n)); else i=$(((i+1)%n)); fi

if [ "${CYCLE_DRY_RUN:-}" = 1 ]; then
  printf '%s\n' "${t[$i]}"
else
  tmux switch-client -t "${t[$i]}"
fi
