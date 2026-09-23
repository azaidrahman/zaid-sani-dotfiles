#!/usr/bin/env bash
# prefix+y: edit the commit message that Claude proposed, then optionally commit.
#
# Claude writes each proposed message to $(git rev-parse --git-dir)/CLAUDE_COMMIT_MSG
# (see "Approval before git history changes" in ~/.claude/CLAUDE.md). The file
# lives inside the git dir, so git never tracks it, and each worktree has its own.
#
# Two modes:
#
#   commit-msg-popup.sh <pane path>      gate, run by run-shell (formats expand)
#   commit-msg-popup.sh --edit <file>    inside the popup: nvim, then "commit now?"
#
# The gate owns the status messages:
#
#   not a git work tree   -> tmux status message, no popup
#   no proposed message   -> tmux status message, no popup
#   message exists        -> popup
#
# On "y" the popup runs `git commit -F <file>` against what is staged, and removes
# the file when the commit succeeds. On any other answer the edited file stays,
# so Claude reads your version when you tell it to commit.
set -euo pipefail

if [[ "${1:-}" == "--edit" ]]; then
  msg=${2:?message file required}
  nvim -c 'setfiletype gitcommit' "$msg"

  if [[ -z "$(grep -v '^[[:space:]]*$' "$msg" 2>/dev/null || true)" ]]; then
    echo "Message is empty. Nothing to commit."
    read -rsn1 -p "Press any key to close."
    exit 0
  fi

  echo "Staged files:"
  if ! git diff --cached --name-status | sed 's/^/  /' | grep .; then
    echo "  (none)"
  fi
  echo
  read -rn1 -p "Commit now? [y/N] " answer
  echo
  if [[ "$answer" == [yY] ]]; then
    if git commit -F "$msg"; then
      rm -f "$msg"
    fi
    read -rsn1 -p "Press any key to close."
  fi
  exit 0
fi

cwd=${1:?pane path required}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/git-popup-size.sh"

if ! git_dir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null); then
  tmux display-message "prefix+y: not a git repo"
  exit 0
fi

msg="$git_dir/CLAUDE_COMMIT_MSG"
if [[ ! -s "$msg" ]]; then
  tmux display-message "prefix+y: no proposed commit message in $(basename "$cwd")"
  exit 0
fi

# display-popup -E passes on the inner exit status. The gate must always give
# run-shell a zero status, or tmux prints a `returned 1` banner.
tmux display-popup -E -w "$POPUP_W" -h "$POPUP_H" -d "$cwd" -T ' commit message ' \
  -- "$script_dir/commit-msg-popup.sh" --edit "$msg" || true
