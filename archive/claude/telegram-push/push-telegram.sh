# shellcheck shell=bash
# Telegram push sink — one entry point, no knowledge of its caller.
#
# SOURCE OF TRUTH: ~/projects/project-working/agent-push
# Its tests/test-push-telegram.sh covers the credential, tier, encoding, and
# detach behaviour in 25 cases. Change the module there first, run those tests,
# then copy the file back here. Do not edit this copy alone.
#
# push_telegram <tier> <title> <subtitle> <message>
#
# `tier` is `attn` (the agent needs you) or `done` (the turn finished). Any other
# value is treated as `done`, so a caller bug fails toward silence instead of
# buzzing the phone.
#
# This module knows only how to talk to Telegram. It does not decide WHETHER you
# should be interrupted — the caller owns that, because presence and Focus state are
# host concerns and a second transport must be able to reuse the same gate.
#
# Source this file, then call the function. It sets no shell options, so it cannot
# change the caller's error handling.

# Keychain service names. Both entries are read with the current user as the
# account, matching the op-service-account-token pattern used elsewhere:
#
#   security add-generic-password -a "$USER" -s telegram-claude-bot-token \
#       -T /usr/bin/security -w <token>
#   security add-generic-password -a "$USER" -s telegram-claude-chat-id \
#       -T /usr/bin/security -w <chat-id>
CLAUDE_PUSH_KC_TOKEN="${CLAUDE_PUSH_KC_TOKEN:-telegram-claude-bot-token}"
CLAUDE_PUSH_KC_CHAT="${CLAUDE_PUSH_KC_CHAT:-telegram-claude-chat-id}"

# Read one secret from the login keychain. If the entry is absent, print nothing.
_push_keychain() {
    security find-generic-password -a "${USER:-$(id -un)}" -s "$1" -w 2>/dev/null
}

push_telegram() {
    # Kill switch first, so it costs nothing to turn the sink off.
    [ -n "${CLAUDE_PUSH_DISABLE:-}" ] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    command -v security >/dev/null 2>&1 || return 0

    local tier="${1:-done}" title="${2:-}" sub="${3:-}" msg="${4:-}"

    # If either credential is missing, do nothing and say nothing. A fresh machine
    # has no bot token yet, and that must not turn every notification into an error.
    local token chat
    token=$(_push_keychain "$CLAUDE_PUSH_KC_TOKEN") || true
    chat=$(_push_keychain "$CLAUDE_PUSH_KC_CHAT") || true
    [ -n "$token" ] && [ -n "$chat" ] || return 0

    local api="${CLAUDE_PUSH_TELEGRAM_API:-https://api.telegram.org}"
    local timeout="${CLAUDE_PUSH_TIMEOUT:-5}"

    # Title, then subtitle, then a blank line, then the body. The first two lines are
    # what the phone shows in a collapsed notification, so the session and the topic
    # must appear before the message.
    local text="$title"
    [ -n "$sub" ] && text="$text
$sub"
    [ -n "$msg" ] && text="$text

$msg"

    # --data-urlencode, not a hand-built query string. Permission prompts carry
    # arbitrary command text: quotes, backticks, ampersands, newlines, and non-ASCII
    # all have to survive verbatim.
    set -- \
        --silent \
        --output /dev/null \
        --max-time "$timeout" \
        --data-urlencode "chat_id=$chat" \
        --data-urlencode "text=$text"

    # attn buzzes. done files quietly into the chat. This mirrors the local tiers,
    # where attn plays its own cue and done lets macOS Focus suppress the chime — a
    # finished turn has no right to interrupt you, only a blocked one does.
    case "$tier" in
        attn) : ;;
        *)    set -- "$@" --data-urlencode "disable_notification=true" ;;
    esac

    # Detached and fully redirected. The caller is a Claude Code hook that runs
    # synchronously on the stop path, so it must never wait on the network. Nothing
    # is printed either way: the bot token sits in the URL, and hook output is
    # logged.
    ( curl "$@" "$api/bot$token/sendMessage" >/dev/null 2>&1 & ) >/dev/null 2>&1
    return 0
}
