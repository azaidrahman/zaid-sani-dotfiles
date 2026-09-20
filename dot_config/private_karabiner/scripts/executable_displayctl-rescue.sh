#!/bin/bash
# displayctl-rescue - Bring the built-in display back when the panel is black.
#
# Karabiner runs this script from hyper+shift+escape. That key works with no
# picture, because Karabiner reads the keyboard below the window server.
#
# Step 1 asks the tool to turn the display on. Step 2 runs only when the panel
# does not come back. It stops the agent. The agent turns the display on by
# itself as it stops, which is a second way to the same result. The agent then
# stays stopped, so nothing turns the display off again. Start it again with
# `,displayctl start` when you can see the screen.
#
# Only aqua has the displayctl tool. On any other Mac this script does nothing.

set -u

bin="$HOME/.config/displayctl/bin/displayctl"
log="$HOME/Library/Logs/displayctl.log"
target="gui/$(id -u)/com.zaid.displayctl"

say() {
	printf '%s displayctl-rescue: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$log"
}

if [[ ! -x $bin ]]; then
	exit 1
fi

say "the rescue key was pressed"

if "$bin" on >>"$log" 2>&1; then
	say "the display is on again"
	exit 0
fi

say "the tool could not turn the display on, so the agent stops now"
launchctl bootout "$target" 2>/dev/null

# A bootout returns before the agent stops. The agent turns the display on
# first, and the plist gives it 20 seconds for that. Wait for 25 seconds at most.
for _ in $(seq 1 250); do
	launchctl print "$target" >/dev/null 2>&1 || break
	sleep 0.1
done

"$bin" on >>"$log" 2>&1
say "the agent is stopped. Run ',displayctl start' when you can see the screen."
