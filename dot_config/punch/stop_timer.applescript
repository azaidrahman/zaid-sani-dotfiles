-- Stop the running Clock.app timer from the Timers tab.
--
-- Clock.app has two layouts. The single layout shows one timer with a
-- Cancel button and a Pause button while it runs. The card layout shows a
-- card per timer; a card has a Close button and then a pause button while
-- it runs. The script clicks Cancel when it sees Pause, or the Close that
-- comes before a pause. It prints "stopped" or "none".
--
-- `entire contents` returns nothing for this window, so the script walks
-- the tree by hand. The window only exposes its buttons while Clock is
-- frontmost, so Clock comes to the front for a moment.

on collect(e, acc)
	tell application "System Events"
		set r to ""
		set d to ""
		try
			set r to role of e
		end try
		try
			set d to description of e
		end try
		if r is "AXButton" then set end of acc to {d, e}
		set kids to {}
		try
			set kids to UI elements of e
		end try
	end tell
	repeat with c in kids
		set acc to my collect(c, acc)
	end repeat
	return acc
end collect

set wasRunning to (application "Clock" is running)
tell application "Clock" to activate
repeat 20 times
	delay 0.25
	tell application "System Events"
		if exists process "Clock" then
			if (count of windows of process "Clock") > 0 then exit repeat
		end if
	end tell
end repeat
delay 0.5

tell application "System Events" to tell process "Clock"
	repeat with r in (radio buttons of toolbar 1 of window 1)
		if description of r is "Timers" and value of r is not 1 then
			click r
			delay 0.5
		end if
	end repeat
end tell

set buttons to {}
tell application "System Events" to set tops to UI elements of window 1 of process "Clock"
repeat with e in tops
	set buttons to my collect(e, buttons)
end repeat

set outcome to "none"
set cancelButton to missing value
set lastClose to missing value
repeat with b in buttons
	set d to item 1 of b
	if d is "Cancel" then set cancelButton to item 2 of b
	if d is "Close" then set lastClose to item 2 of b
	if d is "Pause" and cancelButton is not missing value then
		tell application "System Events" to click cancelButton
		set outcome to "stopped"
		exit repeat
	end if
	if d is "pause" and lastClose is not missing value then
		tell application "System Events" to click lastClose
		set outcome to "stopped"
		exit repeat
	end if
end repeat

if wasRunning then
	tell application "System Events" to set visible of process "Clock" to false
else
	tell application "Clock" to quit
end if
return outcome
