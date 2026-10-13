#!/bin/bash
# Toggle the fuzzy key-search HUD (ctrl+shift+/).
# Compiles the Swift binary on first run or when the source is newer.
DIR="$HOME/.config/karabiner"
BIN="$DIR/scripts/key-search-hud"
SRC="$DIR/src/key-search-hud.swift"
INDEX="$DIR/data/keymap-index.tsv"
FKEY_INDEX="$DIR/data/fkey-index.tsv"

# Toggle: if the HUD is open, close it
if pgrep -xq key-search-hud; then
  killall key-search-hud 2>/dev/null
  exit 0
fi

if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
  /usr/bin/swiftc -O "$SRC" -o "$BIN" || exit 1
fi

"$BIN" "$INDEX" "$FKEY_INDEX" &
