#!/usr/bin/env bash
# handoff.sh — open a terminal tab on a worktree and boot Claude with a brief.
# Inside tmux, the tab is a tmux window. Inside Rex, the tab is a Rex window.
# Usage: handoff.sh <KEY> <WORKTREE_DIR> <BRIEF_PATH> [LABEL]
# Exit:  0 opened|reused · 2 bad input · 3 no tmux and no Rex
set -euo pipefail

KEY=${1:-}; DIR=${2:-}; BRIEF=${3:-}; LABEL=${4:-$KEY}

[ -n "$KEY" ] && [ -n "$DIR" ] && [ -n "$BRIEF" ] || {
  echo "usage: handoff.sh <KEY> <WORKTREE_DIR> <BRIEF_PATH> [LABEL]" >&2; exit 2; }
# The key and the path of the brief are typed into a shell. A control character
# in them would act as a key press, so refuse them before any window opens.
case "$KEY$BRIEF" in
  *[[:cntrl:]]*) echo "control character in the key or in the brief path" >&2; exit 2 ;;
esac
[ -d "$DIR" ]   || { echo "not a directory: $DIR" >&2; exit 2; }
[ -f "$BRIEF" ] || { echo "no brief at: $BRIEF" >&2; exit 2; }

# If this shell is inside tmux, use tmux, also when tmux runs in a Rex pane.
# The user looks at the tmux windows then, not at the Rex tabs.
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null; then
  HOST=tmux
elif [ -n "${REX_SESSION:-}" ] && command -v rex >/dev/null && command -v jq >/dev/null; then
  HOST=rex
else
  echo "no-tmux-or-rex"; exit 3
fi

DIR=$(cd "$DIR" && pwd)
BRIEF=$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")
# Check again: the absolute path takes the name of the current directory, and
# that name can hold a control character that the relative path did not.
case "$BRIEF" in
  *[[:cntrl:]]*) echo "control character in the absolute brief path" >&2; exit 2 ;;
esac
LABEL=$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9 ._-' '-' | cut -c1-25)

PROMPT="Read $BRIEF — it is your handoff brief from the session that filed $KEY. Follow its Next step."

# Open the window on the user's shell, then type the claude command into it.
# If claude were the window command, the window would close when the user
# leaves claude. With a shell under it, the window stays, in the worktree.
# The prompt is typed into a shell, so quote it: close, escape, open.
# HANDOFF_CLAUDE_FLAGS lets the caller pick the model and effort of the new
# session, for example "--model opus --effort high".
QUOTED=$(printf '%s' "$PROMPT" | sed "s/'/'\\\\''/g")
CMD="claude ${HANDOFF_CLAUDE_FLAGS:-} '$QUOTED'"

open_tmux() {
  # Reuse a window that already carries this key. This script tags each window
  # that it opens with the key (@handoff_key), and finds the window again by
  # the tag. The name is only a label: it is cleaned, cut to 25 characters, and
  # the user can rename it.
  #
  # A window with no tag came from an older version of this script, or from
  # prefix+X. For such a window, the name must be the key, or the key and a
  # space and a label. A window with a tag is never matched by its name.
  #
  # Compare as plain text: a regular expression would let GTI-1 match GTI-123.
  # ENVIRON keeps awk from changing a backslash in the key. The empty string in
  # each comparison makes awk compare text, not numbers.
  local tab existing win
  tab=$(printf '\t')
  existing=$(tmux list-windows -F "#{window_id}${tab}#{@handoff_key}${tab}#{window_name}" \
             | KEY="$KEY" awk -F '\t' '
                 BEGIN { k = ENVIRON["KEY"] "" }
                 $2 != "" { if (($2 "") == k && tagged == "") tagged = $1; next }
                 (($3 "") == k || index($3, k " ") == 1) && legacy == "" { legacy = $1 }
                 END { print (tagged != "" ? tagged : legacy) }')
  if [ -n "$existing" ]; then
    tmux select-window -t "$existing"
    echo "window: reused $LABEL"
    return
  fi

  win=$(tmux new-window -P -F '#{window_id}' -c "$DIR" -n "$LABEL")
  tmux set-option -w -t "$win" @handoff_key "$KEY"
  tmux select-pane -t "$win" -T "$LABEL"
  tmux send-keys -t "$win" -l "$CMD"
  tmux send-keys -t "$win" Enter
  echo "window: created $LABEL"
}

open_rex() {
  # Reuse a pane that already carries this key. A Rex window has no place for
  # custom data, so this script puts the tag in the label of the pane (a Rex
  # block): handoff:<KEY>. The window label is only for display, and the user
  # can rename it. jq compares the labels as plain text.
  local session=$REX_SESSION tag="handoff:$KEY" existing created block
  existing=$(rex block ls -s "$session" --json | jq -r --arg t "$tag" \
    'first(.blocks[] | select(.label == $t and .placement == "placed") | .block_id) // empty')
  if [ -n "$existing" ]; then
    rex focus -s "$session" "$existing" >/dev/null
    echo "window: reused $LABEL"
    return
  fi

  # One call makes the window, its shell pane, the tag, and the start directory.
  created=$(jq -n --arg window "$LABEL" --arg tag "$tag" --arg cwd "$DIR" '{
      window_label: $window,
      layout: { block: { flavor: "com.superlogical.terminal.shell",
                         label: $tag, options: { cwd: $cwd } } } }' \
    | rex api call -s "$session" session.new_window -)
  block=$(printf '%s' "$created" | jq -er '.block_ids[0]')
  rex send -s "$session" -b "$block" "$CMD"
  rex send-key -s "$session" -b "$block" enter
  echo "window: created $LABEL"
}

"open_$HOST"
