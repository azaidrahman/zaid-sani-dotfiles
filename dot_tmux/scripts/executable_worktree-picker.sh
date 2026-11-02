#!/usr/bin/env bash
# prefix+e's worktree picker: choose which of the repo's git worktrees to review,
# then open `tuicr -w` there. Reached from claude-diff-review.sh when the repo has
# more than one worktree — see
# docs/superpowers/specs/2026-07-30-prefix-e-worktree-picker-design.md.
#
# Worktrees only. This deliberately does NOT browse directories or filenames the
# way the dir-picker it replaced did; if you want a different directory, cd there
# and press prefix+e again.
#
# Rows are `<marker><branch>\t<short path>\t<abs path>`. fzf shows fields 1-2
# (--with-nth) and prints the whole selected row, which `cut -f3` then reduces
# to the absolute path — so it never has to be parsed back out of the display
# text, and paths with spaces survive intact. (Not --accept-nth: that needs
# fzf >= 0.62, and this box's fzf predates it.)
# The current worktree sorts first and is marked ●, so prefix+e then Enter still
# reviews where you are: the old muscle memory, one keystroke longer.
#
# $1 — pane id, for the conditional `cd` on accept. Or `--list` to print the raw
#      rows and exit (test seam: fzf needs a tty, row rendering does not).
set -euo pipefail

# Rows for every worktree in this repo, current one first.
#
# `git worktree list --porcelain` emits a blank-line-separated block per
# worktree: `worktree <abs path>`, `HEAD <sha>`, then either
# `branch refs/heads/<name>` or `detached`. It reports the whole repo from
# anywhere inside any of its worktrees.
build_rows() {
  local main_root current
  # First porcelain entry is always the main worktree — the root that linked
  # worktrees under .worktrees/ or .claude/worktrees/ are relative to.
  main_root=$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')
  current=$(git rev-parse --show-toplevel 2>/dev/null || true)

  git worktree list --porcelain | awk -v main_root="$main_root" -v current="$current" '
    /^worktree /  { path = substr($0, 10); head = ""; branch = ""; next }
    /^HEAD /      { head = substr($0, 6); next }
    /^branch /    { sub(/^branch refs\/heads\//, "", $0); branch = $0; next }
    /^detached$/  { branch = "~" substr(head, 1, 7); next }
    /^$/          { if (path != "") emit(); next }
    END           { if (path != "") emit() }

    function emit() {
      # Short path: strip the main root prefix when the worktree lives under it.
      # The main worktree itself renders as its basename ("tuicr") rather than
      # "." — relative-to-itself is technically correct but reads as noise.
      short = path
      if (index(path, main_root "/") == 1) short = substr(path, length(main_root) + 2)
      else if (path == main_root)          { n = split(path, p, "/"); short = p[n] }

      label = (branch != "" ? branch : "(no branch)")
      # Current worktree sorts first via a 0/1 sort key, and is marked.
      if (path == current) printf "0\t● %s\t%s\t%s\n", label, short, path
      else                 printf "1\t  %s\t%s\t%s\n", label, short, path
      path = ""
    }
  ' | sort -s -t"$(printf '\t')" -k1,1 | cut -f2-
}

if [[ "${1:-}" == "--list" ]]; then
  build_rows
  exit 0
fi

pane_id=${1:?pane id required}

rows=$(build_rows)
[[ -n "$rows" ]] || { tmux display-message "prefix+e: no worktrees found"; exit 0; }

# `cut -f3` reduces fzf's selected row to the absolute path (see the header
# comment on why not --accept-nth). Cancelling (Esc/Ctrl-C) yields an empty
# selection and a non-zero fzf status; both mean "user changed their mind", so
# exit cleanly rather than letting set -e surface it as a tmux error. The
# `|| true` guards the WHOLE pipeline (fzf | cut -f3), so pipefail's rule of
# reporting the rightmost non-zero exit still lands on `true`, not on a
# cancelled fzf.
sel=$(printf '%s\n' "$rows" \
  | fzf --delimiter='\t' --with-nth=1,2 \
        --prompt 'worktree> ' --header-lines=0 --no-multi \
  | cut -f3 \
  || true)
[[ -n "$sel" ]] || exit 0

[[ -d "$sel" ]] || { tmux display-message "prefix+e: worktree is gone (run: git worktree prune)"; exit 0; }

# Only type `cd` into the triggering pane when a real shell owns it — sending
# keystrokes to a running Claude or vim pastes literal text instead of executing.
# The path goes in single quotes. The line editor of the shell can read some
# characters as keys, for example a carriage return or a byte above 0x7f.
# Thus type the cd only if the path has plain ASCII characters from a short
# list. -l sends the text as literal characters, never as tmux key names.
#
# safe_path PATH — true if PATH has only letters, digits, space and ._/@+~-.
# The C locale makes the ranges plain ASCII in each locale.
safe_path() { local LC_ALL=C; [[ "$1" != *[!A-Za-z0-9._/@+~\ -]* ]]; }

if safe_path "$sel"; then
  case "$(tmux display-message -p -t "$pane_id" '#{pane_current_command}')" in
    sh | bash | zsh | fish)
      tmux send-keys -t "$pane_id" -l "cd -- '$sel'"
      tmux send-keys -t "$pane_id" C-m
      ;;
  esac
fi

cd "$sel"
# A deliberately-chosen worktree may still be clean, and tuicr exits 1 with
# "No changes to review". That is the honest answer, not a script failure — `||
# true` keeps tmux from adding a `returned 1` banner on top of tuicr's message.
#
# NOT `exec tuicr -w || true`: exec replaces this shell, so the `|| true` would
# never run and tuicr's exit 1 would become the script's exit status — exactly
# the banner we are trying to avoid. Run it as a child instead.
tuicr -w || true
