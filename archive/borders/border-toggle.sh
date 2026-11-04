#!/bin/bash
# Turn the window borders on or off.
# If borders runs, stop it. If borders does not run, start it.

BORDERS=/opt/homebrew/opt/borders/bin/borders

if pgrep -x borders >/dev/null; then
	killall borders
else
	"$BORDERS" &
	sleep 0.3
	~/.config/borders/border-focus.sh
fi
