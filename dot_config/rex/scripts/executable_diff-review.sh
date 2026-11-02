#!/usr/bin/env bash
# The gate of tmux prefix+e, in a Rex float (diff_review.lua).
#
#   diff-review.sh <pane path> [<session id> <block id>]
#
# The tmux gate (~/.tmux/scripts/popups/claude-diff-review.sh) shows its
# messages with tmux. This script does the same checks, and shows the
# messages in the float:
#
#   not a git work tree      -> a message in the float
#   more than one worktree   -> pick a worktree in fzf, then `tuicr -w` there
#   one worktree, changes    -> `tuicr -w` in the pane path
#   one worktree, no changes -> a message in the float
#
# A message closes the float after a few seconds, or when you press a key.
#
# The rows of the picker come from the --list form of the tmux picker
# (~/.tmux/scripts/worktree-picker.sh). The current worktree is the first row.
# If you pick a worktree and a shell owns the pane (the block id), the gate
# types `cd` into that pane, as in tmux. It does not type into Claude or nvim.
#
# `tuicr -w` reviews the uncommitted changes. tuicr keeps the comments in its
# session store, so Claude can read them with `tuicr review comments`.
set -euo pipefail

PICKER=${WORKTREE_PICKER:-$HOME/.tmux/scripts/worktree-picker.sh}

# A message stays this number of seconds, if you do not press a key.
MESSAGE_SECONDS=3

cwd=${1:?pane path required}
session=${2:-}
block=${3:-}

# say shows a message, then closes the float.
say() {
  printf '\n  %s\n\n' "$1"
  read -rsn1 -t "$MESSAGE_SECONDS" -p "  Press any key to close." || true
  exit 0
}

# changed DIR — true if the work tree of DIR has changes.
changed() { [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]; }

if ! git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  say "Not a git repo: $cwd"
fi

# The porcelain list gives all worktrees of the repo, from any of them.
# `grep -c` exits 1 on a zero count, so `|| true` stops set -e.
worktrees=$(git -C "$cwd" worktree list --porcelain | grep -c '^worktree ' || true)

if [[ "${worktrees:-0}" -le 1 ]]; then
  changed "$cwd" || say "No changes in $(basename "$cwd")."
  cd "$cwd"
  # tuicr can exit 1, for example if an agent commits before it starts. Its
  # status is not a failure of the gate.
  tuicr -w || true
  exit 0
fi

cd "$cwd"
rows=$(bash "$PICKER" --list)
[[ -n "$rows" ]] || say "No worktrees found."

# fzf shows the branch and the short path, and prints the whole row. `cut -f3`
# keeps the absolute path. Esc gives an empty selection: close the float.
sel=$(printf '%s\n' "$rows" |
  fzf --delimiter='\t' --with-nth=1,2 --prompt 'worktree> ' --no-multi |
  cut -f3 || true)
[[ -n "$sel" ]] || exit 0
[[ -d "$sel" ]] || say "The worktree is gone. Run: git worktree prune"

# Type `cd` only into a shell. In Claude or nvim, the keys become text. The
# path goes in single quotes. If the path has a quote or a new line, the shell
# can run part of it as a command, so do not type the cd.
unsafe=$'\'\n'
if [[ -n "$block" && "$sel" != *["$unsafe"]* ]]; then
  foreground=$(rex block call ${session:+-s "$session"} -b "$block" process 2>/dev/null |
    jq -r '.foreground.name // empty' 2>/dev/null || true)
  case "$foreground" in
    sh | bash | zsh | fish)
      rex send ${session:+-s "$session"} -b "$block" "cd -- '$sel'" &&
        rex send-key ${session:+-s "$session"} -b "$block" enter || true
      ;;
  esac
fi

changed "$sel" || say "No changes in $(basename "$sel")."
cd "$sel"
tuicr -w || true
