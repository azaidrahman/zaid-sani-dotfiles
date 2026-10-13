#!/bin/sh
# Float the focused Arc window and move it to a workspace.
# Usage: arc-float-window.sh <workspace>
#
# The Keyboard Maestro macro "Arc: Move Current Tab to New Window" calls
# this script after it makes a new Arc window. Aerospace moves every new
# Arc window to workspace 1 and tiles it. This script moves the window to
# the workspace that was in use, then floats it and focuses it.
set -eu

workspace="${1:?usage: arc-float-window.sh <workspace>}"
aero=/opt/homebrew/bin/aerospace
arc_bundle=company.thebrowser.Browser

focused=$("$aero" list-windows --focused --format '%{window-id} %{app-bundle-id} %{workspace}')
case "$focused" in
  *"$arc_bundle"*) ;;
  *)
    echo "arc-float-window: the focused window is not an Arc window" >&2
    exit 1
    ;;
esac
set -- $focused
window=$1
current=$3

# Aerospace stops with an error when the window is already on the workspace.
if [ "$current" != "$workspace" ]; then
  "$aero" move-node-to-workspace --window-id "$window" "$workspace"
fi
"$aero" layout --window-id "$window" floating
"$aero" focus --window-id "$window"
