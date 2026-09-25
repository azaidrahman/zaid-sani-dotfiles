#!/usr/bin/env bash
# prefix+y: edit a draft that Claude proposed. A draft is a commit message or a
# pull request. The commit popup can also do the commit.
#
# Claude writes each draft into the git dir (see "Approval before git history
# changes" in ~/.agents/AGENTS.md). Git never tracks the files, and each
# worktree has its own:
#
#   $(git rev-parse --absolute-git-dir)/CLAUDE_COMMIT_MSG   commit message
#   $(git rev-parse --absolute-git-dir)/CLAUDE_PR_MSG       pull request draft
#
# Modes:
#
#   commit-msg-popup.sh <pane path> [commit|pr]  gate, run by run-shell
#   commit-msg-popup.sh --edit <file>     inside the popup: `git commit -v` in nvim
#   commit-msg-popup.sh --editor <file>   the GIT_EDITOR that --edit gives to git
#   commit-msg-popup.sh --edit-pr <file>  inside the popup: nvim on the PR draft
#
# The gate owns the status messages:
#
#   not a git work tree   -> tmux status message, no popup
#   no draft              -> tmux status message, no popup
#   one draft             -> popup for that draft
#   both drafts           -> menu to choose the draft. The menu runs the gate
#                            again with commit or pr, which opens that popup.
#
# The popup runs `git commit -v -e -F <file>`. Git opens nvim on COMMIT_EDITMSG
# with the proposed message at the top, and the status and staged diff below it,
# the same as a plain `git commit -v`.
#
#   :wq            commit, then remove the proposed message file
#   :q             abort, the proposed message file stays
#   :cq            abort, and save your edits to the proposed message file
#   empty message  abort (the rule of git), the proposed message file stays
#
# The buffer already holds the message, so git commits on any clean nvim exit,
# :q too. The --editor wrapper stops that: if you did not write the buffer, it
# exits 1, and git aborts.
#
# After an abort, Claude reads your edited version when you tell it to commit.
#
# The pull request popup only edits the draft. Claude reads the file again when
# you tell it to open the pull request.
set -euo pipefail

if [[ "${1:-}" == "--edit-pr" ]]; then
  draft=${2:?draft file required}
  before=$(cksum <"$draft")
  nvim "$draft" || true
  if [[ -f "$draft" && "$(cksum <"$draft")" != "$before" ]]; then
    echo "Your edits are saved for Claude."
  else
    echo "No change."
  fi
  read -rsn1 -p "Press any key to close."
  exit 0
fi

if [[ "${1:-}" == "--editor" ]]; then
  file=${2:?file required}
  # Set an old mtime. If nvim writes the file, the mtime changes.
  touch -t 200001010000 "$file"
  before=$(stat -f %m "$file")
  nvim "$file" || exit 1
  [[ "$(stat -f %m "$file")" != "$before" ]]
  exit
fi

if [[ "${1:-}" == "--edit" ]]; then
  msg=${2:?message file required}
  editmsg="$(dirname "$msg")/COMMIT_EDITMSG"

  if GIT_EDITOR="bash '${BASH_SOURCE[0]}' --editor" git commit -v -e -F "$msg"; then
    rm -f "$msg"
  else
    echo "Not committed."
  fi
  if [[ -f "$msg" && "$editmsg" -nt "$msg" ]]; then
    # Git leaves the edited buffer in COMMIT_EDITMSG. Copy the message part back,
    # without the comments and the diff under the scissors line. The -nt test
    # skips a stale file from an earlier commit. Git also writes the file when
    # nothing is staged, so save only when the text changed.
    edited=$(sed '/^# -* >8 -*$/,$d' "$editmsg" | git stripspace --strip-comments)
    if [[ -n "$edited" && "$edited" != "$(git stripspace --strip-comments <"$msg")" ]]; then
      printf '%s\n' "$edited" >"$msg"
      echo "Your edits are saved for Claude."
    fi
  fi
  read -rsn1 -p "Press any key to close."
  exit 0
fi

cwd=${1:?pane path required}
kind=${2:-}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
self="$script_dir/commit-msg-popup.sh"
source "$script_dir/git-popup-size.sh"

if ! git_dir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null); then
  tmux display-message "prefix+y: not a git repo"
  exit 0
fi

msg="$git_dir/CLAUDE_COMMIT_MSG"
pr="$git_dir/CLAUDE_PR_MSG"

if [[ -z "$kind" ]]; then
  if [[ -s "$msg" && -s "$pr" ]]; then
    tmux display-menu -x C -y C -T ' edit which draft? ' \
      "commit message" c "run-shell \"'$self' '$cwd' commit\"" \
      "pull request draft" p "run-shell \"'$self' '$cwd' pr\""
    exit 0
  elif [[ -s "$msg" ]]; then
    kind="commit"
  elif [[ -s "$pr" ]]; then
    kind="pr"
  else
    tmux display-message "prefix+y: no commit message or pull request draft in $(basename "$cwd")"
    exit 0
  fi
fi

case "$kind" in
  commit) file=$msg mode=--edit title="commit message" ;;
  pr) file=$pr mode=--edit-pr title="pull request draft" ;;
  *)
    tmux display-message "prefix+y: unknown draft kind: $kind"
    exit 0
    ;;
esac

# Claude can remove the file while the menu is open.
if [[ ! -s "$file" ]]; then
  tmux display-message "prefix+y: no $title in $(basename "$cwd")"
  exit 0
fi

# display-popup -E passes on the inner exit status. The gate must always give
# run-shell a zero status, or tmux prints a `returned 1` banner.
tmux display-popup -E -w "$POPUP_W" -h "$POPUP_H" -d "$cwd" -T " $title " \
  -- "$self" "$mode" "$file" || true
