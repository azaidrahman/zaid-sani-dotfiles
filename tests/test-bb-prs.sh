#!/usr/bin/env bash
# Tests for dot_local/bin/executable_bb-prs (prefix+B).
#
# The tests use JSON fixtures, a fake `twg` that records its arguments, and a
# local bare repo as origin. They never call Bitbucket. Run with bash.
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dot_local/bin/executable_bb-prs"
fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        printf 'ok   - %s\n' "$1"
    else
        printf 'FAIL - %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export BB_PRS_TTY="$tmp/tty" XDG_CACHE_HOME="$tmp/cache" XDG_STATE_HOME="$tmp/state"
# Your git config can sign commits and run hooks. The test must not use it.
printf '[user]\n\tname = t\n\temail = t@example.com\n' >"$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
# shellcheck source=/dev/null
source "$SCRIPT"
set +e

# --- bb_remote_repo -------------------------------------------------------------
git init -q "$tmp/repo"
check "no remote" "" "$(bb_remote_repo "$tmp/repo")"
while IFS='|' read -r url want; do
    git -C "$tmp/repo" remote remove origin 2>/dev/null
    git -C "$tmp/repo" remote add origin "$url"
    check "remote $url" "$want" "$(bb_remote_repo "$tmp/repo")"
done <<'EOF'
https://someone@bitbucket.org/ws/repo.git|ws/repo
https://bitbucket.org/ws/repo|ws/repo
git@bitbucket.org:ws/repo.git|ws/repo
git@github.com:owner/repo.git|
EOF

# --- bb_rows --------------------------------------------------------------------
# PR 11 is in the repo query and the author inbox. PR 12 is in the repo query
# and the reviewer inbox. The inbox role must win, and the current repo goes first.
pr() { # id author-uuid
    printf '{"id":%s,"title":"t%s","draft":false,"author":{"uuid":"%s","display_name":"a"},"links":{"html":{"href":"https://bitbucket.org/ws/cur/pull-requests/%s"}}}' \
        "$1" "$1" "$2" "$1"
}
item() { # repo id
    printf '{"id":%s,"repo":"%s","title":"t","draft":false,"link":"https://bitbucket.org/%s/pull-requests/%s","author":{"displayName":"a"}}' \
        "$2" "$1" "$1" "$2"
}
printf '[%s,%s,%s]' "$(pr 10 '{o}')" "$(pr 11 '{me}')" "$(pr 12 '{o}')" >"$tmp/q"
printf '{"currentUser":{"uuid":"{me}"},"items":[%s,%s]}' "$(item ws/cur 12)" "$(item ws/other 5)" >"$tmp/r"
printf '{"currentUser":{"uuid":"{me}"},"items":[%s,%s]}' "$(item ws/cur 11)" "$(item ws/zzz 7)" >"$tmp/a"
check "rows: dedupe, roles, order" \
    "ws/cur 12 review|ws/cur 11 mine|ws/cur 10 open|ws/other 5 review|ws/zzz 7 mine" \
    "$(bb_rows "$tmp/q" "$tmp/r" "$tmp/a" ws/cur | awk -F'\t' '{print $1, $2, $3}' | paste -sd'|' -)"
: >"$tmp/empty"
check "rows: all sources empty" "" "$(bb_rows "$tmp/empty" "$tmp/empty" "$tmp/empty" ws/cur)"
# The closed list: the role is the state, and the newest PR goes first.
printf '[{"id":1,"state":"MERGED","updated_on":"2026-01-01","links":{"html":{"href":"https://bitbucket.org/ws/cur/pull-requests/1"}}},{"id":2,"state":"DECLINED","updated_on":"2026-02-01","links":{"html":{"href":"https://bitbucket.org/ws/cur/pull-requests/2"}}}]' >"$tmp/closed"
check "rows: closed list" "2 declined|1 merged" \
    "$(bb_rows "$tmp/closed" "$tmp/empty" "$tmp/empty" ws/cur closed | awk -F'\t' '{print $2, $3}' | paste -sd'|' -)"

# --- bb_merge -------------------------------------------------------------------
# Your own PR gets no approval. Error rows, closed PRs and log rows are
# skipped. "n" merges nothing. Each action goes into the log.
mkdir "$tmp/bin"
printf '#!/bin/sh\necho "$*" >>"%s/twg.log"\n' "$tmp" >"$tmp/bin/twg"
chmod +x "$tmp/bin/twg"
printf '%s\n' $'ws/cur\t11\tmine\tu\td' $'ws/cur\t12\treview\tu\td' $'ws/cur\t13\tmerged\tu\td' \
    $'ws/cur\t14\tlog\tu\td' $'\t\t\t\t! could not load' >"$tmp/sel"
merge_log() { # answer
    : >"$tmp/twg.log"
    printf '%s\n' "$1" >"$tmp/tty"
    (PATH="$tmp/bin:$PATH" bb_merge "$tmp/sel" >/dev/null 2>&1)
    paste -sd'|' - <"$tmp/twg.log"
}
flags="--merge-strategy merge_commit --close-source-branch --wait"
check "merge: approve others, merge all" \
    "bitbucket pull-requests merge --pull-request 11 --repo ws/cur $flags|bitbucket pull-requests approve 12 --repo ws/cur|bitbucket pull-requests merge --pull-request 12 --repo ws/cur $flags" \
    "$(merge_log y)"
check "merge: actions in the log" "merge ok 11|approve ok 12|merge ok 12" \
    "$(awk -F'\t' '{print $2, $3, $5}' "$tmp/state/bb-prs/actions.tsv" | paste -sd'|' -)"
check "merge: n merges nothing" "" "$(merge_log n)"

# --- sync_one -------------------------------------------------------------------
# feat is one commit behind main and rebases clean. clash changes the same
# line as main, so its rebase stops. Either way no worktree stays behind.
git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
w="$tmp/work"
commit() { printf '%s\n' "$2" >"$w/$1" && git -C "$w" add "$1" && git -C "$w" commit -qm "$2"; }
commit a.txt base
git -C "$w" push -q origin HEAD:main
git -C "$w" checkout -q -b feat && commit b.txt feat && git -C "$w" push -q origin feat
git -C "$w" checkout -q -b clash main && commit a.txt clash && git -C "$w" push -q origin clash
git -C "$w" checkout -q main && commit a.txt main2 && git -C "$w" push -q origin main
git -C "$w" fetch -q origin
o="$tmp/origin.git"
clash_before=$(git -C "$o" rev-parse clash)
sync_one "$w" feat main >/dev/null 2>&1
check "sync: clean rebase is pushed" "0 1" \
    "$(git -C "$o" rev-list --count feat..main) $(git -C "$o" rev-list --count main..feat)"
sync_one "$w" clash main >/dev/null 2>&1
check "sync: conflict returns 2" "2" "$?"
check "sync: conflict leaves the branch" "$clash_before" "$(git -C "$o" rev-parse clash)"
check "sync: no worktree stays" "1" "$(git -C "$w" worktree list | wc -l | tr -d ' ')"

exit "$fail"
