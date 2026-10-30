#!/usr/bin/env bash
# Tests for dot_local/bin/executable_bb-prs (prefix+B).
#
# The tests use JSON fixtures and a fake `twg` that records its arguments.
# They never call Bitbucket. Run with bash.
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
export BB_PRS_TTY="$tmp/tty"
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

# --- bb_merge -------------------------------------------------------------------
# Your own PR gets no approval. Error rows are skipped. "n" merges nothing.
mkdir "$tmp/bin"
printf '#!/bin/sh\necho "$*" >>"%s/twg.log"\n' "$tmp" >"$tmp/bin/twg"
chmod +x "$tmp/bin/twg"
printf 'ws/cur\t11\tmine\tu\td\nws/cur\t12\treview\tu\td\n\t\t\t\t! could not load\n' >"$tmp/sel"
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
check "merge: n merges nothing" "" "$(merge_log n)"

exit "$fail"
