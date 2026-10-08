#!/usr/bin/env bash
# handoff.sh — open a tmux window on a worktree and boot Claude with a brief.
# Usage: handoff.sh <KEY> <WORKTREE_DIR> <BRIEF_PATH> [LABEL]
# Exit:  0 opened|reused · 2 bad input · 3 no tmux
set -euo pipefail

KEY=${1:-}; DIR=${2:-}; BRIEF=${3:-}; LABEL=${4:-$KEY}

[ -n "$KEY" ] && [ -n "$DIR" ] && [ -n "$BRIEF" ] || {
  echo "usage: handoff.sh <KEY> <WORKTREE_DIR> <BRIEF_PATH> [LABEL]" >&2; exit 2; }
[ -d "$DIR" ]   || { echo "not a directory: $DIR" >&2; exit 2; }
[ -f "$BRIEF" ] || { echo "no brief at: $BRIEF" >&2; exit 2; }

command -v tmux >/dev/null || { echo "no-tmux"; exit 3; }
[ -n "${TMUX:-}" ] || { echo "no-tmux"; exit 3; }

DIR=$(cd "$DIR" && pwd)
BRIEF=$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")
LABEL=$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9 ._-' '-' | cut -c1-25)

# Reuse a window that already carries this key. The name of the window is the
# key, or the key and a space and a label. Compare as plain text: a regular
# expression would let GTI-1 match GTI-123, and would let a "." match any
# character. ENVIRON keeps awk from changing a backslash in the key.
EXISTING=$(tmux list-windows -F '#{window_id} #{window_name}' \
           | KEY="$KEY" awk '{ name = substr($0, length($1) + 2)
                               if (name == ENVIRON["KEY"] || index(name, ENVIRON["KEY"] " ") == 1) { print $1; exit } }')
if [ -n "$EXISTING" ]; then
  tmux select-window -t "$EXISTING"
  echo "window: reused $LABEL"
  exit 0
fi

PROMPT="Read $BRIEF — it is your handoff brief from the session that filed $KEY. Follow its Next step."

# Open the window on the user's shell, then type the claude command into it.
# If claude were the window command, the window would close when the user
# leaves claude. With a shell under it, the window stays, in the worktree.
# The prompt is typed into a shell, so quote it: close, escape, open.
QUOTED=$(printf '%s' "$PROMPT" | sed "s/'/'\\\\''/g")
WIN=$(tmux new-window -P -F '#{window_id}' -c "$DIR" -n "$LABEL")
tmux select-pane -t "$WIN" -T "$LABEL"
tmux send-keys -t "$WIN" -l "claude '$QUOTED'"
tmux send-keys -t "$WIN" Enter
echo "window: created $LABEL"
