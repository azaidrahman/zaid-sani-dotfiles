#!/usr/bin/env bash
# The gate of tmux prefix+y, in a Rex float (commit_draft.lua).
#
#   commit-draft.sh <pane path> [commit|pr]
#
# Claude writes each draft into the git dir of the repo or worktree (see
# "Approval before git history changes" in ~/.agents/AGENTS.md):
#
#   $(git rev-parse --absolute-git-dir)/CLAUDE_COMMIT_MSG   commit message
#   $(git rev-parse --absolute-git-dir)/CLAUDE_PR_MSG       pull request draft
#
# The tmux gate (~/.tmux/scripts/popups/commit-msg-popup.sh) shows its
# messages and its menu with tmux. This script shows them in the float:
#
#   not a git work tree   -> a message in the float
#   no draft              -> a message in the float
#   one draft             -> the editor for that draft
#   both drafts           -> a menu in the float: c (commit) or p (pull request)
#
# A message closes the float after a few seconds, or when you press a key.
# The editor is the --edit or --edit-pr mode of the tmux script. Thus the keys
# are the same as in tmux: in the commit draft, :wq commits and :cq keeps your
# edits for Claude. In the pull request draft, :w saves it for Claude.
set -euo pipefail

EDIT_SCRIPT=${COMMIT_MSG_POPUP:-$HOME/.tmux/scripts/popups/commit-msg-popup.sh}

# A message stays this number of seconds, if you do not press a key.
MESSAGE_SECONDS=3

cwd=${1:?pane path required}
kind=${2:-}

# say shows a message, then closes the float.
say() {
  printf '\n  %s\n\n' "$1"
  read -rsn1 -t "$MESSAGE_SECONDS" -p "  Press any key to close." || true
  exit 0
}

if ! git_dir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null); then
  say "Not a git repo: $cwd"
fi

msg="$git_dir/CLAUDE_COMMIT_MSG"
pr="$git_dir/CLAUDE_PR_MSG"

if [[ -z "$kind" ]]; then
  if [[ -s "$msg" && -s "$pr" ]]; then
    printf '\n  Edit which draft?\n\n    c  commit message\n    p  pull request draft\n\n'
    key=""
    read -rsn1 -p "  Any other key closes. " key || true
    case "$key" in
      c) kind="commit" ;;
      p) kind="pr" ;;
      *) exit 0 ;;
    esac
  elif [[ -s "$msg" ]]; then
    kind="commit"
  elif [[ -s "$pr" ]]; then
    kind="pr"
  else
    say "No commit message or pull request draft in $(basename "$cwd")."
  fi
fi

case "$kind" in
  commit) file=$msg mode=--edit title="commit message" ;;
  pr) file=$pr mode=--edit-pr title="pull request draft" ;;
  *) say "Unknown draft kind: $kind" ;;
esac

# Claude can remove the file while the menu is open.
if [[ ! -s "$file" ]]; then
  say "No $title in $(basename "$cwd")."
fi

# The --edit mode runs `git commit` in the current directory.
cd "$cwd"
exec "$EDIT_SCRIPT" "$mode" "$file"
