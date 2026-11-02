#!/usr/bin/env bash
# Tests for the tools that keep 1Password prompts off a Mac where you are not:
#   dot_local/shims/executable_op                    the op wrapper
#   dot_local/bin/executable_op-sa.tmpl              service-account runner
#   dot_local/bin/executable_ssh-agent-seed.tmpl     agent seed
#
# Each command that touches 1Password, SSH, the keychain, or the system is a
# stub. The test never calls the real op, ssh, ssh-add, or security.
#
# Run with: bash tests/test-op-approval.sh

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

stub() {
    mkdir -p "$(dirname "$1")"
    cat >"$1"
    chmod +x "$1"
}

LOG=$tmp/log

mkdir -p "$tmp/home" "$tmp/shims"
cp "$repo_root/dot_local/shims/executable_op" "$tmp/shims/op"
chmod +x "$tmp/shims/op"

# --- Stubs on this Mac --------------------------------------------------------

stub "$tmp/bin/op" <<'SH'
#!/bin/sh
{ echo "LOCAL"; for a in "$@"; do echo "arg=$a"; done; } >>"$LOG"
SH

stub "$tmp/bin/ioreg" <<'SH'
#!/bin/sh
echo "    | |   \"HIDIdleTime\" = $(( ${FAKE_LOCAL_IDLE:-0} * 1000000000 ))"
SH

stub "$tmp/bin/scutil" <<'SH'
#!/bin/sh
echo "${FAKE_HOST:-aqua}"
SH

# Tripwires: the wrapper must never touch the ssh-agent or load keys. A call
# adds a line to the log, so each case below fails.
stub "$tmp/bin/ssh-add" <<'SH'
#!/bin/sh
echo "UNEXPECTED ssh-add $*" >>"$LOG"
SH

stub "$tmp/bin/ssh-agent-seed" <<'SH'
#!/bin/sh
echo "UNEXPECTED ssh-agent-seed $*" >>"$LOG"
SH

# The ssh stub answers the idle probe, or runs the command in zsh (the login
# shell on the peer) with the PATH of the peer.
stub "$tmp/bin/ssh" <<'SH'
#!/bin/sh
stdin=yes
while [ $# -gt 0 ]; do
    case $1 in
        -n) stdin=no ;;
        -o) shift ;;
        -*) ;;
        *) break ;;
    esac
    shift
done
host=$1
cmd=$2
[ "${FAKE_SSH_DOWN:-0}" = 1 ] && exit 255
case $cmd in
    *HIDIdleTime*) echo "${FAKE_PEER_IDLE:-5}"; exit 0 ;;
esac
[ "${FAKE_SSH_CMD_DOWN:-0}" = 1 ] && exit 255
echo "SSH host=$host stdin=$stdin" >>"$LOG"
[ "$stdin" = no ] && exec </dev/null
PATH=$PEER_PATH SSH_CONNECTION="10.0.0.1 1 10.0.0.2 22" exec zsh -f -c "$cmd"
SH

# --- Stubs on the peer --------------------------------------------------------

stub "$tmp/peerbin/op" <<'SH'
#!/bin/sh
{ echo "PEER from=${OP_APPROVE_FROM:-}"; for a in "$@"; do echo "arg=$a"; done; } >>"$LOG"
SH

# Skip the -e script lines, and log the message and the title.
stub "$tmp/peerbin/osascript" <<'SH'
#!/bin/sh
while [ "$1" = -e ]; do shift 2; done
echo "NOTIFY $1 | $2" >>"$LOG"
SH

LOCAL_PATH="$tmp/shims:$tmp/bin:/usr/bin:/bin"
PEER_PATH="$tmp/shims:$tmp/peerbin:/usr/bin:/bin"

# check NAME WANT [VAR=value ...] -- [op args ...]
# Defaults: this Mac is aqua, idle 600 s; the peer is idle 5 s.
check() {
    local name=$1 want=$2
    shift 2
    local -a envs=()
    while [ "$1" != "--" ]; do
        envs+=("$1")
        shift
    done
    shift
    : >"$LOG"
    env -i HOME="$tmp/home" PATH="$LOCAL_PATH" LOG="$LOG" \
        PEER_PATH="$PEER_PATH" FAKE_LOCAL_IDLE=600 FAKE_PEER_IDLE=5 \
        ${envs[@]+"${envs[@]}"} \
        "$tmp/shims/op" "$@" </dev/null >/dev/null 2>&1 || true
    local got
    got=$(cat "$LOG")
    [ "$got" = "$want" ] || fail "$name
--- want
$want
--- got
$got"
}

ref='op://Personal Development/it'\''s "x" $HOME/f'
local_read=$'LOCAL\narg=read\narg='"$ref"
peer_read=$'SSH host=onyx stdin=no\nNOTIFY op read '"$ref"$' | 1Password request from aqua\nPEER from=aqua\narg=read\narg='"$ref"

# --- The op wrapper -------------------------------------------------------------

check "you are at this Mac: run here" "$local_read" FAKE_LOCAL_IDLE=5 -- read "$ref"
check "you are at the peer: run there, with the same args" "$peer_read" -- read "$ref"
check "the peer is idle longer: run here" "$local_read" FAKE_PEER_IDLE=9000 -- read "$ref"
check "a forced peer skips the idle checks" "$peer_read" OP_APPROVE_HOST=onyx FAKE_LOCAL_IDLE=0 -- read "$ref"
check "a forced host that is not aqua or onyx: run here" "$local_read" OP_APPROVE_HOST=evil.example -- read "$ref"
check "a service-account token: run here" "$local_read" OP_SERVICE_ACCOUNT_TOKEN=t -- read "$ref"
check "an inbound SSH call: run here" "$local_read" SSH_CONNECTION="1 2 3 4" -- read "$ref"
check "the peer is down: run here" "$local_read" FAKE_SSH_DOWN=1 -- read "$ref"
check "SSH fails for the command: run here" "$local_read" FAKE_SSH_CMD_DOWN=1 -- read "$ref"
check "op run stays here" $'LOCAL\narg=run\narg=--\narg=env' -- run -- env
check "a file output stays here" $'LOCAL\narg=read\narg=--out-file=/tmp/x\narg=r' -- read --out-file=/tmp/x r
check "a short -o in a group stays here" $'LOCAL\narg=read\narg=-no\narg=/tmp/x\narg=r' -- read -no /tmp/x r
check "item create stays here" $'LOCAL\narg=item\narg=create\narg=x' -- item create x
check "global flags before item get" \
    $'SSH host=onyx stdin=no\nNOTIFY op --format json item get LiteLLM login | 1Password request from aqua\nPEER from=aqua\narg=--format\narg=json\narg=item\narg=get\narg=LiteLLM login' \
    -- --format json item get "LiteLLM login"

check "inject stays here: the notification cannot show its secrets" $'LOCAL\narg=inject' -- inject

# --- op-sa ----------------------------------------------------------------------

mkdir -p "$tmp/sa"
sed 's/{{ .workVaultName }}/Work Vault/g' "$repo_root/dot_local/bin/executable_op-sa.tmpl" >"$tmp/sa/op-sa"
chmod +x "$tmp/sa/op-sa"

stub "$tmp/sa/security" <<'SH'
#!/bin/sh
[ "${FAKE_NO_TOKEN:-0}" = 1 ] && exit 44
while [ $# -gt 0 ]; do
    [ "$1" = -s ] && { echo "token-for-$2"; exit 0; }
    shift
done
exit 1
SH

stub "$tmp/sa/op" <<'SH'
#!/bin/sh
echo "token=$OP_SERVICE_ACCOUNT_TOKEN args=$*"
SH

# check_sa NAME WANT_RC WANT_OUT [VAR=value ...] -- [args ...]
check_sa() {
    local name=$1 want_rc=$2 want=$3
    shift 3
    local -a envs=()
    while [ "$1" != "--" ]; do
        envs+=("$1")
        shift
    done
    shift
    local got rc=0
    got=$(env -i HOME="$tmp/home" USER=tester PATH="$tmp/sa:/usr/bin:/bin" \
        ${envs[@]+"${envs[@]}"} "$tmp/sa/op-sa" "$@" 2>/dev/null) || rc=$?
    [ "$rc" = "$want_rc" ] || fail "op-sa: $name: want exit $want_rc, got $rc"
    [ "$got" = "$want" ] || fail "op-sa: $name: want [$want] got [$got]"
}

work=token-for-op-service-account-token
personal=token-for-op-service-account-token-personal
check_sa "work vault ref" 0 "token=$work args=read op://Work Vault/i/f" -- read "op://Work Vault/i/f"
check_sa "personal vault ref" 0 "token=$personal args=read op://Personal Development/i/f" -- read "op://Personal Development/i/f"
check_sa "--vault value" 0 "token=$personal args=item get --vault Personal Development i" -- item get --vault "Personal Development" i
check_sa "--vault=value" 0 "token=$work args=item get --vault=Work Vault i" -- item get "--vault=Work Vault" i
check_sa "no account for Private" 3 "" -- read "op://Private/i/f"
check_sa "no vault in the args" 3 "" -- item list
check_sa "token not in the keychain" 3 "" FAKE_NO_TOKEN=1 -- read "op://Personal Development/i/f"

# --- ssh-agent-seed -------------------------------------------------------------

mkdir -p "$tmp/seed"
sed 's/{{ .workVaultName }}/Work Vault/g' "$repo_root/dot_local/bin/executable_ssh-agent-seed.tmpl" >"$tmp/seed/ssh-agent-seed"
chmod +x "$tmp/seed/ssh-agent-seed"
cp "$tmp/bin/scutil" "$tmp/seed/scutil"

stub "$tmp/seed/op-sa" <<'SH'
#!/bin/sh
[ "${FAKE_SA_OK:-1}" = 1 ] || exit 3
echo "sa-key"
SH

stub "$tmp/seed/op" <<'SH'
#!/bin/sh
echo "touch-id-key"
SH

# Like the real ssh-add, fail when no key comes in on stdin.
stub "$tmp/seed/ssh-add" <<'SH'
#!/bin/sh
[ "$1" = -l ] && exit 1
key=$(cat)
[ -n "$key" ] || exit 1
echo "ADD $key" >>"$LOG"
SH

# check_seed NAME WANT_RC WANT_LOG [VAR=value ...] -- [args ...]
check_seed() {
    local name=$1 want_rc=$2 want=$3
    shift 3
    local -a envs=()
    while [ "$1" != "--" ]; do
        envs+=("$1")
        shift
    done
    shift
    : >"$LOG"
    local rc=0
    env -i HOME="$tmp/home" PATH="$tmp/seed:/usr/bin:/bin" LOG="$LOG" \
        SSH_AUTH_SOCK="$tmp/agent.sock" FAKE_HOST=aqua \
        ${envs[@]+"${envs[@]}"} "$tmp/seed/ssh-agent-seed" "$@" </dev/null >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$want_rc" ] || fail "seed: $name: want exit $want_rc, got $rc"
    local got
    got=$(cat "$LOG")
    [ "$got" = "$want" ] || fail "seed: $name: want [$want] got [$got]"
}

check_seed "service account first" 0 $'ADD sa-key\nADD sa-key' --
check_seed "Touch ID when the service account fails" 0 $'ADD touch-id-key\nADD touch-id-key' FAKE_SA_OK=0 --
check_seed "--headless never asks for Touch ID" 1 "" FAKE_SA_OK=0 -- --headless

echo "PASS: test-op-approval"
