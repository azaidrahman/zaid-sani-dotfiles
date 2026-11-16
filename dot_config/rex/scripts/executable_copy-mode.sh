#!/bin/sh
# Rex copy mode. Show the text of one pane in nvim.
# Use: copy-mode.sh SESSION_ID PANE_ID [jump]
# With jump, nvim starts with a jump to a word. See copy-mode-nvim.lua.
# The text stays in memory. The script writes no file.
# On an error, the script shows a message and waits for Enter.

dir=${0%/*}

fail() {
	printf 'copy mode: %s\n' "$1"
	printf 'Press Enter to close.\n'
	read -r _
	exit 1
}

command -v nvim >/dev/null 2>&1 || fail 'nvim is not installed on this host.'

# Capture first, so that an error shows before nvim starts.
text=$(rex capture -s "$1" -b "$2" --trim --unwrap) || fail 'the pane could not be read.'

printf '%s\n' "$text" | REX_COPY_JUMP=${3:-} nvim -R -n --noplugin -u "$dir/copy-mode-nvim.lua" + -
