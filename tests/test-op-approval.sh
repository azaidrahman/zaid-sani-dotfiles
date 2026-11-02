#!/usr/bin/env bash
# Tests for the tools that keep 1Password prompts off a Mac where you are not:
#   dot_local/shims/executable_op                    the op wrapper
#   dot_local/bin/executable_ssh-agent-seed.tmpl     agent seed
#   dot_local/bin/executable_git-sign.tmpl           commit signing
#
# The op-sa window itself has its own tests: tests/test-op-sa-window.sh.
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

# --- ssh-agent-seed -------------------------------------------------------------

mkdir -p "$tmp/seed"
sed 's/{{ .workVaultName }}/Work Vault/g' "$repo_root/dot_local/bin/executable_ssh-agent-seed.tmpl" >"$tmp/seed/ssh-agent-seed"
chmod +x "$tmp/seed/ssh-agent-seed"
cp "$tmp/bin/scutil" "$tmp/seed/scutil"

# FAKE_SA_OK=0 is a closed op-sa window: ttl and read fail with status 3.
stub "$tmp/seed/op-sa" <<'SH'
#!/bin/sh
[ "${FAKE_SA_OK:-1}" = 1 ] || exit 3
case $1 in
    ttl) echo 600 ;;
    read) [ "${FAKE_READ_OK:-1}" = 1 ] && echo "sa-key" ;;
esac
SH

stub "$tmp/seed/op" <<'SH'
#!/bin/sh
echo "touch-id-key"
SH

# Like the real ssh-add, fail when no key comes in on stdin. An added key
# goes in $AGENT, so `ssh-add -L` lists it.
stub "$tmp/seed/ssh-add" <<'SH'
#!/bin/sh
case $1 in
    -l) exit 1 ;;
    -L) cat "$AGENT" 2>/dev/null; exit 0 ;;
esac
key=$(cat)
[ -n "$key" ] || exit 1
echo "ADD t=$2 $key" >>"$LOG"
echo "${FAKE_LOADED_KEY:-}" >>"$AGENT"
SH
AGENT=$tmp/agent-keys

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
    : >"$AGENT"
    local rc=0
    env -i HOME="$tmp/home" PATH="$tmp/seed:/usr/bin:/bin" LOG="$LOG" AGENT="$AGENT" \
        SSH_AUTH_SOCK="$tmp/agent.sock" FAKE_HOST=aqua \
        ${envs[@]+"${envs[@]}"} "$tmp/seed/ssh-agent-seed" "$@" </dev/null >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$want_rc" ] || fail "seed: $name: want exit $want_rc, got $rc"
    local got
    got=$(cat "$LOG")
    [ "$got" = "$want" ] || fail "seed: $name: want [$want] got [$got]"
}

# A key from the service account leaves the agent when the window closes.
check_seed "service account first, until the window closes" 0 $'ADD t=600 sa-key\nADD t=600 sa-key' --
check_seed "Touch ID when the window is closed" 0 $'ADD t=43200 touch-id-key\nADD t=43200 touch-id-key' FAKE_SA_OK=0 --
check_seed "--headless never asks for Touch ID" 1 "" FAKE_SA_OK=0 -- --headless

# --- git-sign -------------------------------------------------------------------

# git-sign uses the same stubs as ssh-agent-seed. When the key loads, it runs
# the real /usr/bin/ssh-keygen, which fails here because there is no agent.
# The test checks only what went into the agent.
sed 's/{{ .workVaultName }}/Work Vault/g' "$repo_root/dot_local/bin/executable_git-sign.tmpl" >"$tmp/seed/git-sign"
chmod +x "$tmp/seed/git-sign"
work_blob=AAAAC3NzaC1lZDI1NTE5AAAAIK+RKQKLiD4MzerLtLjTEST
echo "ssh-ed25519 $work_blob test" >"$tmp/work.pub"

# check_sign NAME WANT_RC WANT_LOG WANT_ERR [VAR=value ...]
check_sign() {
    local name=$1 want_rc=$2 want=$3 want_err=$4
    shift 4
    : >"$LOG"
    : >"$AGENT"
    local rc=0
    env -i HOME="$tmp/home" PATH="$tmp/seed:/usr/bin:/bin" LOG="$LOG" AGENT="$AGENT" \
        SSH_AUTH_SOCK="$tmp/no-agent.sock" FAKE_HOST=aqua FAKE_LOADED_KEY="ssh-ed25519 $work_blob" "$@" \
        "$tmp/seed/git-sign" -Y sign -n git -f "$tmp/work.pub" </dev/null >/dev/null 2>"$tmp/err" || rc=$?
    [ -z "$want_rc" ] || [ "$rc" = "$want_rc" ] || fail "git-sign: $name: want exit $want_rc, got $rc"
    [ "$(cat "$LOG")" = "$want" ] || fail "git-sign: $name: want [$want] got [$(cat "$LOG")]"
    grep -q -- "$want_err" "$tmp/err" || fail "git-sign: $name: stderr does not say [$want_err]: $(cat "$tmp/err")"
}

check_sign "closed: fail at once" 1 "" "op-sa unlock" FAKE_SA_OK=0
check_sign "open: the key leaves the agent when the window closes" "" "ADD t=600 sa-key" ""
check_sign "1Password fails: fail at once" 1 "" "cannot load the signing key" FAKE_READ_OK=0

echo "PASS: test-op-approval"
