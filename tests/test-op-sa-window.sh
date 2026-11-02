#!/usr/bin/env bash
# Tests for the op-sa window, which keeps the 1Password service-account tokens
# in memory for a limited time:
#   dot_config/op-sa-window/src/op-sa-window.swift   the helper that holds them
#   dot_local/bin/executable_op-sa.tmpl              service-account runner
#   dot_local/bin/executable_git-credential-op.tmpl  git credential helper
#
# The test builds the real helper and runs it on a socket in a temporary HOME.
# It never calls the real op, and it never touches the keychain: a stub of
# `security` fails the test if a tool calls it.
#
# Run with: bash tests/test-op-sa-window.sh

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
home=$tmp/home
helper=$home/.config/op-sa-window/bin/op-sa-window
sock=$home/.local/state/op-sa-window/sock
server_pid=""

stop_server() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=""
    fi
}
trap 'stop_server; rm -rf "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

mkdir -p "$(dirname "$helper")"
swiftc -O -swift-version 5 "$repo_root/dot_config/op-sa-window/src/op-sa-window.swift" \
    -o "$helper" 2>"$tmp/build.log" || { cat "$tmp/build.log" >&2; fail "the helper does not build"; }

start_server() {
    stop_server
    HOME=$home "$helper" serve 2>>"$tmp/server.log" &
    server_pid=$!
    for _ in $(seq 1 50); do
        [ -S "$sock" ] && return 0
        sleep 0.1
    done
    fail "the helper did not make its socket"
}

# Wait up to 3 seconds for the helper to stop by itself.
server_stops() {
    for _ in $(seq 1 30); do
        kill -0 "$server_pid" 2>/dev/null || { wait "$server_pid" 2>/dev/null || true; server_pid=""; return 0; }
        sleep 0.1
    done
    return 1
}

# expect NAME WANT_RC WANT_OUT STDIN -- ARGS...
expect() {
    local name=$1 want_rc=$2 want=$3 input=$4
    shift 5
    local got rc=0
    got=$(printf '%s' "$input" | HOME=$home "$helper" "$@" 2>/dev/null) || rc=$?
    [ "$rc" = "$want_rc" ] || fail "helper: $name: want exit $want_rc, got $rc"
    [ "$got" = "$want" ] || fail "helper: $name: want [$want] got [$got]"
}

# --- The helper -----------------------------------------------------------------

start_server
second_rc=0
HOME=$home "$helper" serve 2>/dev/null || second_rc=$?
[ "$second_rc" != 0 ] || fail "helper: a second helper started while one runs"
expect "closed: get gives nothing" 3 "" "" -- get sa.work
expect "closed: put is refused" 3 "" "v" -- put pat.github
expect "a payload line with no '=' is refused" 2 "" "garbage" -- open 60
expect "a window longer than 12 hours is refused" 2 "" "sa.work=w" -- open 43201
expect "a refused open leaves the window closed" 3 "" "" -- get sa.work
expect "open" 0 "" $'sa.work=ops_w 1\nsa.personal=ops_p\n' -- open 60
expect "get gives the exact value" 0 "ops_w 1" "" -- get sa.work
expect "a key that is not there" 4 "" "" -- get pat.github
expect "put" 0 "" "pat-1" -- put pat.github
expect "get after put" 0 "pat-1" "" -- get pat.github
expect "del" 0 "" "" -- del pat.github
expect "get after del" 4 "" "" -- get pat.github

# A client that connects and sends nothing must not block other clients.
sleep 5 | nc -U "$sock" >/dev/null 2>&1 &
stuck=$!
sleep 0.2
HOME=$home "$helper" get sa.personal >/dev/null 2>&1 &
quick=$!
for _ in $(seq 1 10); do
    kill -0 "$quick" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$quick" 2>/dev/null && fail "helper: a stuck client blocks the next request"
wait "$quick" || fail "helper: get failed while a stuck client was connected"
kill "$stuck" 2>/dev/null || true

expect "lock" 0 "" "" -- lock
server_stops || fail "helper: it did not stop after lock"
expect "after lock, the window is closed" 3 "" "" -- get sa.work

start_server
expect "open for 1 second" 0 "" "sa.work=w" -- open 1
server_stops || fail "helper: it did not stop when the window ran out"
expect "after expiry, the window is closed" 3 "" "" -- get sa.work

# --- op-sa ----------------------------------------------------------------------

LOG=$tmp/log
bin=$tmp/bin
mkdir -p "$bin"
sed 's/{{ .workVaultName }}/Work Vault/g' "$repo_root/dot_local/bin/executable_op-sa.tmpl" >"$bin/op-sa"
chmod +x "$bin/op-sa"

# The op stub logs each call. With no service-account token, `item get` is
# the unlock call: it gives the two tokens, like the real
# `op item get --fields label=work,label=personal --reveal`.
cat >"$bin/op" <<'SH'
#!/bin/sh
{ echo "OP token=${OP_SERVICE_ACCOUNT_TOKEN:-none}"; for a in "$@"; do echo "arg=$a"; done; } >>"$LOG"
case "${OP_SERVICE_ACCOUNT_TOKEN:-none} $1 $2" in
    "none item get") printf '%s\n' "${FAKE_TOKENS-ops_work,ops_personal}" ;;
    *)
        if [ -n "${FAKE_OP_FAIL:-}" ]; then
            echo "[ERROR] $FAKE_OP_FAIL" >&2
            exit 1
        fi
        echo "token=${OP_SERVICE_ACCOUNT_TOKEN:-none} args=$*" ;;
esac
SH
chmod +x "$bin/op"

# Tripwire: no tool may read or write the keychain.
cat >"$bin/security" <<'SH'
#!/bin/sh
echo "UNEXPECTED security $*" >>"$LOG"
exit 1
SH
chmod +x "$bin/security"

# run_sa [VAR=value ...] -- ARGS...   Sets $out, $err, and $rc.
run_sa() {
    local -a envs=()
    while [ "$1" != "--" ]; do
        envs+=("$1")
        shift
    done
    shift
    rc=0
    out=$(env -i HOME="$home" PATH="$bin:/usr/bin:/bin:/usr/sbin" LOG="$LOG" \
        ${envs[@]+"${envs[@]}"} "$bin/op-sa" "$@" 2>"$tmp/err") || rc=$?
    err=$(cat "$tmp/err")
}

# check_sa NAME WANT_RC WANT_OUT [VAR=value ...] -- ARGS...
check_sa() {
    local name=$1 want_rc=$2 want=$3
    shift 3
    run_sa "$@"
    [ "$rc" = "$want_rc" ] || fail "op-sa: $name: want exit $want_rc, got $rc ($err)"
    [ "$out" = "$want" ] || fail "op-sa: $name: want [$want] got [$out]"
}

unlock_call=$'OP token=none\narg=item\narg=get\narg=op-sa window\narg=--vault\narg=Private\narg=--fields\narg=label=work,label=personal\narg=--reveal'

start_server
: >"$LOG"
check_sa "closed: read fails" 3 "" -- read "op://Work Vault/i/f"
[ ! -s "$LOG" ] || fail "op-sa: closed: op was called"
case $err in *"op-sa unlock"*) ;; *) fail "op-sa: closed: the message does not say 'op-sa unlock': $err" ;; esac

: >"$LOG"
run_sa OP_SERVICE_ACCOUNT_TOKEN=stale -- unlock
[ "$rc" = 0 ] || fail "op-sa: unlock: exit $rc ($err)"
[ "$(cat "$LOG")" = "$unlock_call" ] || fail "op-sa: unlock: want one op call
--- want
$unlock_call
--- got
$(cat "$LOG")"

check_sa "work vault ref" 0 "token=ops_work args=read op://Work Vault/i/f" -- read "op://Work Vault/i/f"
check_sa "personal vault ref" 0 "token=ops_personal args=read op://Personal Development/i/f" -- read "op://Personal Development/i/f"
check_sa "--vault value" 0 "token=ops_personal args=item get --vault Personal Development i" -- item get --vault "Personal Development" i
check_sa "--vault=value" 0 "token=ops_work args=item get --vault=Work Vault i" -- item get "--vault=Work Vault" i
check_sa "no service account for Private" 3 "" -- read "op://Private/i/f"
check_sa "no vault in the args" 3 "" -- item list

for spec in 30s:30 2m:120 1h:3600; do
    run_sa -- unlock --for "${spec%%:*}"
    [ "$rc" = 0 ] || fail "op-sa: unlock --for ${spec%%:*}: exit $rc ($err)"
    run_sa -- ttl
    want=${spec#*:}
    [ "$rc" = 0 ] && [ "$out" -le "$want" ] && [ "$out" -gt $((want - 5)) ] ||
        fail "op-sa: unlock --for ${spec%%:*}: ttl is [$out], want about $want"
done

: >"$LOG"
check_sa "--for longer than 12 hours is refused" 2 "" -- unlock --for 13h
[ ! -s "$LOG" ] || fail "op-sa: a refused --for called op"

check_sa "lock" 0 "op-sa: the window is closed on $(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]')" -- lock
server_stops || fail "op-sa: lock did not stop the helper"
check_sa "after lock, status says closed" 3 "op-sa: the window is closed on $(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]')" -- status

start_server
check_sa "op output that is not two tokens: unlock fails" 1 "" FAKE_TOKENS=ops_one -- unlock
check_sa "a token with a comma: unlock fails" 1 "" FAKE_TOKENS=ops_a,ops_b,ops_c -- unlock
check_sa "after a failed unlock, the window stays closed" 3 "" -- read "op://Work Vault/i/f"

# --- git-credential-op ----------------------------------------------------------

sed 's/{{ .workVaultName }}/Work Vault/g' "$repo_root/dot_local/bin/executable_git-credential-op.tmpl" \
    >"$bin/git-credential-op"
chmod +x "$bin/git-credential-op"
tag=$(scutil --get LocalHostName | tr '[:lower:]' '[:upper:]')
gh_pat="token=ops_personal args=read op://Personal Development/$tag.PAT.GH/credential"
bb_item="op://Work Vault/Bitbucket.$tag.API_TOKEN"

# check_cred NAME ACTION HOST WANT_OUT WANT_LOG [VAR=value ...]
check_cred() {
    local name=$1 action=$2 host=$3 want=$4 want_log=$5
    shift 5
    : >"$LOG"
    local got rc=0
    got=$(printf 'protocol=https\nhost=%s\n\n' "$host" |
        env -i HOME="$home" PATH="$bin:/usr/bin:/bin:/usr/sbin" LOG="$LOG" "$@" \
            "$bin/git-credential-op" "$action" 2>"$tmp/err") || rc=$?
    [ "$rc" = 0 ] || fail "git-credential-op: $name: exit $rc"
    [ "$got" = "$want" ] || fail "git-credential-op: $name: want [$want] got [$got]"
    [ "$(cat "$LOG")" = "$want_log" ] || fail "git-credential-op: $name: want log [$want_log] got [$(cat "$LOG")]"
}

gh_read=$'OP token=ops_personal\narg=read\narg=op://Personal Development/'"$tag"$'.PAT.GH/credential'

start_server
check_cred "closed: quit, with no op call" get github.com "quit=1" ""
grep -q 'op-sa unlock' "$tmp/err" || fail "git-credential-op: closed: the message does not say 'op-sa unlock'"
check_cred "a host that is not github or bitbucket: no answer" get example.com "" ""

run_sa -- unlock
check_cred "github: read 1Password" get github.com $'username=x-access-token\npassword='"$gh_pat" "$gh_read"
check_cred "github: the next get uses the window" get github.com $'username=x-access-token\npassword='"$gh_pat" ""
check_cred "bitbucket: read the token and the user" get bitbucket.org \
    $'username=token=ops_work args=read '"$bb_item"$'/username\npassword=token=ops_work args=read '"$bb_item/credential" \
    $'OP token=ops_work\narg=read\narg='"$bb_item"$'/credential\nOP token=ops_work\narg=read\narg='"$bb_item/username"
check_cred "bitbucket: the next get uses the window" get bitbucket.org \
    $'username=token=ops_work args=read '"$bb_item"$'/username\npassword=token=ops_work args=read '"$bb_item/credential" ""
check_cred "erase" erase github.com "" ""
check_cred "after erase, get reads 1Password again" get github.com $'username=x-access-token\npassword='"$gh_pat" "$gh_read"
check_cred "erase bitbucket" erase bitbucket.org "" ""
check_cred "1Password fails: quit" get bitbucket.org "quit=1" \
    $'OP token=ops_work\narg=read\narg='"$bb_item/credential" FAKE_OP_FAIL="item not found"
grep -q 'item not found' "$tmp/err" || fail "git-credential-op: 1Password fails: the message does not show the error of op"

run_sa -- lock
server_stops || fail "git-credential-op: lock did not stop the helper"
start_server
check_cred "after lock, no token is left" get github.com "quit=1" ""

echo "PASS: test-op-sa-window"
