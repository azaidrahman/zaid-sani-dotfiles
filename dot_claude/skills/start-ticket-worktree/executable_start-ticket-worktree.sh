#!/usr/bin/env bash
# start-ticket.sh — deterministic core of the start-ticket skill.
#
# Given an ALREADY-RESOLVED ticket key, branch type, and slug, set up an isolated
# git worktree on a properly-named branch (<type>/<KEY>-<slug>) at
# .worktrees/<KEY>-<slug>, and OPTIONALLY a Rex window (tab) rooted in that
# worktree. Personal override of the gtech-skills version: Rex replaces tmux.
# Idempotent and safe for repeated / concurrent invocation, so several
# processes (a multi-ticket batch loop, the worklog skill, a human at the shell)
# can all call it without stepping on each other.
#
# The JUDGMENT steps stay OUT of this script on purpose — resolving an ambiguous
# key, fetching Jira, the Epic-vs-Task check, and mapping an unlisted issue type
# all require a human/agent decision. Derive KEY, TYPE and SLUG up front (the
# start-ticket SKILL.md Steps 1–4 rules), then hand them here.
#
# Usage:
#   start-ticket.sh <KEY> <TYPE> <SLUG> [options]
#
#   <KEY>    Jira key, uppercase, e.g. GTI-273   (validated [A-Z]+-[0-9]+)
#   <TYPE>   one of: feat fix chore docs
#   <SLUG>   kebab-case, <=30 chars, no leading/trailing '-'
#
# Options:
#   --session        also open a Rex window in $REX_SESSION, rooted in the worktree
#   --no-fetch       skip 'git fetch' (a batch loop fetches once, then passes this)
#   --base <BRANCH>  base branch to branch from (default: resolve origin/HEAD,
#                    fall back to develop then main)
#   --repo <PATH>    repo to operate in (default: toplevel of the current dir)
#   --no-setup       do not run worktree-setup.sh (also: WORKTREE_SETUP=0)
#
# stdout: machine-parseable status lines, one per resource —
#   worktree: created|reused|tracked-remote  <BRANCH>  <WORKTREE_DIR>
#   session:  created|already-live|skipped:<reason>  <NAME>
#   setup:    started|running|already-done|skipped:<reason>  [<LOG>]
#             (worktree-setup.sh installs dependencies in the background)
#
# Exit codes:
#   0  worktree is ready (session per --session); safe-to-proceed
#   2  bad input / not a git repo / fetch failed  (message on stderr)
#   4  worktree path exists but is NOT a registered worktree — STOP, ask a human;
#      it may hold someone's uncommitted work. This script never removes or
#      --force's over it.
set -euo pipefail

die()  { echo "start-ticket: $*" >&2; exit 2; }
halt() { echo "start-ticket: $*" >&2; exit 4; }

# ---- parse args -------------------------------------------------------------
KEY=${1:-}; TYPE=${2:-}; SLUG=${3:-}
[ -n "$KEY" ] && [ -n "$TYPE" ] && [ -n "$SLUG" ] \
  || die "usage: $0 <KEY> <TYPE> <SLUG> [--session] [--no-fetch] [--no-setup] [--base B] [--repo P]"
shift 3 || true

WANT_SESSION=0
DO_FETCH=1
DO_SETUP=1
[ "${WORKTREE_SETUP:-1}" = 0 ] && DO_SETUP=0
BASE=""
REPO_ARG="."
while [ $# -gt 0 ]; do
  case "$1" in
    --session)  WANT_SESSION=1 ;;
    --no-fetch) DO_FETCH=0 ;;
    --no-setup) DO_SETUP=0 ;;
    --base)     BASE=${2:-}; shift ;;
    --repo)     REPO_ARG=${2:-}; shift ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

# ---- validate the naming contract (cheap, fail fast) ------------------------
case "$KEY"  in [A-Z]*-[0-9]*) ;; *) die "bad key '$KEY' (expected e.g. GTI-273, uppercase)";; esac
case "$TYPE" in feat|fix|chore|docs) ;;            *) die "bad type '$TYPE' (one of: feat fix chore docs)";; esac
case "$SLUG" in
  -*|*-) die "bad slug '$SLUG' (no leading/trailing '-')";;
  *[!a-z0-9-]*) die "bad slug '$SLUG' (lowercase a-z, 0-9, '-' only)";;
esac
[ "${#SLUG}" -le 30 ] || die "bad slug '$SLUG' (${#SLUG} chars > 30 cap)"

# ---- resolve repo + compose names -------------------------------------------
REPO=$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null) \
  || die "not a git repo: $REPO_ARG"
g() { git -C "$REPO" "$@"; }

# Serialize worktree setup across ticketed and ticketless callers. Git protects
# refs, but a repository-wide lock also serializes fetches and the check/create
# sequence below.
COMMON_DIR=$(g rev-parse --git-common-dir)
case "$COMMON_DIR" in
  /*) ;;
  *) COMMON_DIR="$REPO/$COMMON_DIR" ;;
esac
COMMON_DIR=$(cd "$COMMON_DIR" && pwd -P)
LOCK="$COMMON_DIR/agent-worktree.lock"
LOCK_HELD=0
release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    rmdir "$LOCK" 2>/dev/null || true
  fi
}
trap release_lock EXIT HUP INT TERM
for _ in $(seq 1 60); do
  if mkdir "$LOCK" 2>/dev/null; then
    LOCK_HELD=1
    break
  fi
  sleep 1
done
[ "$LOCK_HELD" -eq 1 ] || halt "timed out waiting for repository worktree lock: $LOCK"

BRANCH="$TYPE/$KEY-$SLUG"
TAIL="$KEY-$SLUG"
WT="$REPO/.worktrees/$TAIL"
# Contract rule 4: branch tail == worktree dir tail, byte-for-byte.
[ "${BRANCH##*/}" = "${WT##*/}" ] || die "internal: naming mismatch ${BRANCH##*/} != ${WT##*/}"

# ---- fetch + resolve base ---------------------------------------------------
if [ "$DO_FETCH" -eq 1 ]; then
  g fetch --prune origin >/dev/null 2>&1 || die "git fetch failed (check remote/network)"
fi
if [ -z "$BASE" ]; then
  BASE=$(g symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)
  if [ -z "$BASE" ]; then
    if   g show-ref --verify --quiet refs/remotes/origin/develop; then BASE=develop
    elif g show-ref --verify --quiet refs/remotes/origin/main;    then BASE=main
    else die "cannot resolve base branch (origin/HEAD unset; no origin/develop or origin/main)"; fi
  fi
fi

# ---- worktree: conflict matrix (idempotent) ---------------------------------
# Already a worktree on this exact branch? Reuse it — never recreate.
if g worktree list --porcelain | grep -qx "branch refs/heads/$BRANCH"; then
  existing=$(g worktree list --porcelain \
    | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{p=$2} $0==b{print p; exit}')
  echo "worktree: reused $BRANCH ${existing:-$WT}"
  WT=${existing:-$WT}
elif [ -e "$WT" ]; then
  # Path exists but isn't registered as the worktree for this branch — do NOT
  # touch it. Could be a stale checkout with real work. Human decision.
  halt "path exists but is not a worktree for $BRANCH: $WT (refusing to overwrite)"
elif g show-ref --verify --quiet "refs/heads/$BRANCH"; then
  g worktree add "$WT" "$BRANCH" >/dev/null
  echo "worktree: reused $BRANCH $WT"            # local branch existed; attached a worktree to it
elif g show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  g worktree add -B "$BRANCH" "$WT" "origin/$BRANCH" >/dev/null
  echo "worktree: tracked-remote $BRANCH $WT"
else
  g worktree add -b "$BRANCH" "$WT" "origin/$BASE" >/dev/null
  echo "worktree: created $BRANCH $WT"
fi

# ---- optional Rex window (personal override: Rex replaces tmux) -------------
# --session opens a Rex window (a tab) in the current Rex session ($REX_SESSION),
# with one shell block that starts in the worktree. The window is not focused,
# so a batch does not move the user.
#   - name     = sanitized worktree tail  (<KEY>-<slug>, '.'/':' -> '-'), used
#                as the window label. The user can rename the window.
#   - tag      = the label of the shell block: ticket:<KEY>. Rex windows have
#                no custom data, so the tag goes on the block (as handoff.sh does).
#   - liveness = a placed block with the label ticket:<KEY> or handoff:<KEY>.
#                A handoff tab for the same ticket counts as already-live.
# stdout keeps the tmux contract: session: created|already-live|skipped:<reason> <NAME>
if [ "$WANT_SESSION" -eq 1 ]; then
  name=${TAIL//[.:]/-}
  if [ -z "${REX_SESSION:-}" ]; then
    echo "session: skipped:no-rex $name"
  elif ! command -v rex >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "session: skipped:no-rex-cli $name"
  else
    live=$(rex block ls -s "$REX_SESSION" --json 2>/dev/null | jq -r \
      --arg t "ticket:$KEY" --arg h "handoff:$KEY" \
      'first(.blocks[] | select((.label == $t or .label == $h) and .placement == "placed") | .block_id) // empty' \
      || true)
    if [ -n "$live" ]; then
      echo "session: already-live $name"
    else
      created=$(jq -n --arg window "$name" --arg tag "ticket:$KEY" --arg cwd "$WT" '{
          window_label: $window,
          layout: { block: { flavor: "com.superlogical.terminal.shell",
                             label: $tag, options: { cwd: $cwd } } } }' \
        | rex api call -s "$REX_SESSION" session.new_window - 2>/dev/null || true)
      if printf '%s' "$created" | jq -e '.block_ids[0]' >/dev/null 2>&1; then
        echo "session: created $name"
      else
        echo "session: skipped:rex-error $name"
      fi
    fi
  fi
fi

# ---- tmux session (disabled: the user moved from tmux to Rex) ---------------
# Naming + liveness MATCH worklog-tmux-session.sh exactly, so the two scripts
# never create duplicate sessions for the same ticket:
#   - session name = sanitized worktree tail  (<KEY>-<slug>, '.'/':' -> '-')
#   - liveness     = any session whose name starts with the key  (^<KEY>(-|$))
#     so a bare-key session (e.g. "GTI-273") counts as already-live too.
# if [ "$WANT_SESSION" -eq 1 ]; then
#   if ! command -v tmux >/dev/null 2>&1; then
#     echo "session: skipped:no-tmux ${TAIL//[.:]/-}"
#   else
#     live=$(tmux list-sessions -F '#S' 2>/dev/null | grep -E "^${KEY}(-|$)" | head -1 || true)
#     if [ -n "$live" ]; then
#       echo "session: already-live $live"
#     else
#       name=${TAIL//[.:]/-}
#       if tmux has-session -t "=$name" 2>/dev/null; then
#         echo "session: already-live $name"
#       else
#         # new-session -d boots a server if none is running; safe outside tmux too.
#         tmux new-session -d -s "$name" -c "$WT"
#         echo "session: created $name"
#       fi
#     fi
#   fi
# fi

# ---- prepare the worktree (dependencies, local files) -----------------------
# worktree-setup.sh decides what to do, starts the slow part detached, and
# returns at once. It never fails the worktree: the worktree is ready either
# way, and a failed setup shows in its log and status file.
SETUP="$(dirname "${BASH_SOURCE[0]}")/worktree-setup.sh"
if [ "$DO_SETUP" -eq 0 ]; then
  echo "setup: skipped:disabled"
elif [ ! -x "$SETUP" ]; then
  echo "setup: skipped:no-setup-script"
elif [ "$(cat "$(git -C "$WT" rev-parse --absolute-git-dir)/worktree-setup.status" 2>/dev/null || true)" = done ]; then
  echo "setup: already-done"
else
  "$SETUP" "$WT" --background 2>/dev/null || echo "setup: skipped:error"
fi

exit 0
