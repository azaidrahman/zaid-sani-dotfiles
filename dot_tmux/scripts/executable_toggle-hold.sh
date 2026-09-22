#!/usr/bin/env bash
# Toggle the [HOLD] marker on the current tmux session (prefix+b).
#
# A held session is blocked on something external. It stays visible, but it
# moves out of the default view of the `tmux-windows` channel (prefix+f) and
# out of the prefix+[ / prefix+] rotation.
#
# The marker is the session name itself. This makes the state visible in the
# status bar and in choose-tree, with no other storage. tmux matches a target
# by exact name before it tries a pattern, so the brackets are safe in a
# target such as `[HOLD] gti-197:0`.
set -u

HOLD_PREFIX='[HOLD] '

sid=$(tmux display-message -p '#{session_id}') || exit 0
name=$(tmux display-message -p '#{session_name}') || exit 0

case "$name" in
    "$HOLD_PREFIX"*)
        new=${name#"$HOLD_PREFIX"}
        state="off"
        ;;
    *)
        new="$HOLD_PREFIX$name"
        state="on"
        ;;
esac

if err=$(tmux rename-session -t "$sid" -- "$new" 2>&1); then
    tmux display-message "HOLD $state: $new"
else
    tmux display-message "HOLD unchanged: $err"
fi
