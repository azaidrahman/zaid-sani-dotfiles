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
#   commit-msg-popup.sh --edit <file>    inside the popup: `git commit -v` in nvim
#
# The gate owns the status messages:
#
#   not a git work tree   -> tmux status message, no popup
#   no proposed message   -> tmux status message, no popup
#   message exists        -> popup
#
# The popup runs `git commit -v -e -F <file>`. Git opens nvim on COMMIT_EDITMSG
# with the proposed message at the top, and the status and staged diff below it,
# the same as a plain `git commit -v`.
#
#   :wq            commit, then remove the proposed message file
#   :cq            abort, and save your edits to the proposed message file
#   empty message  abort (the rule of git), the proposed message file stays
#
# After an abort, Claude reads your edited version when you tell it to commit.
set -euo pipefail

if [[ "${1:-}" == "--edit" ]]; then
  msg=${2:?message file required}
  editmsg="$(dirname "$msg")/COMMIT_EDITMSG"

  if GIT_EDITOR=nvim git commit -v -e -F "$msg"; then
    rm -f "$msg"
  elif [[ "$editmsg" -nt "$msg" ]]; then
    # Git leaves the edited buffer in COMMIT_EDITMSG. Copy the message part back,
    # without the comments and the diff under the scissors line. The -nt test
    # skips a stale file from an earlier commit. Git also writes the file when
    # nothing is staged, so save only when the text changed.
    edited=$(sed '/^# -* >8 -*$/,$d' "$editmsg" | git stripspace --strip-comments)
    if [[ -n "$edited" && "$edited" != "$(git stripspace --strip-comments <"$msg")" ]]; then
      printf '%s\n' "$edited" >"$msg"
      echo "Not committed. Your edits are saved for Claude."
    fi
  fi
  read -rsn1 -p "Press any key to close."
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
