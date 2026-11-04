#!/bin/bash
# Set the color of the border of the focused window.
# AeroSpace calls this script on each change of focus.
#
# Green: AeroSpace tiles the window.
# Grey:  the window floats, or AeroSpace does not manage the window.

BORDERS=/opt/homebrew/opt/borders/bin/borders
AEROSPACE=/opt/homebrew/bin/aerospace

TILED_COLOR="glow(0xd900FF33)"
FLOATING_COLOR=0x60494d64

layout=$("$AEROSPACE" list-windows --focused --format '%{window-layout}' 2>/dev/null)

if [ -n "$layout" ] && [ "$layout" != "floating" ]; then
	"$BORDERS" active_color="$TILED_COLOR"
else
	"$BORDERS" active_color="$FLOATING_COLOR"
fi
