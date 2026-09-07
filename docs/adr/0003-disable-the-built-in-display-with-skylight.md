# Disable the built-in display with a private SkyLight function

aqua sits on a desk with two external monitors. The lid stays open, because the
keyboard and the trackpad are in use. The built-in panel is then a third screen
that nobody looks at. It still takes windows, it still holds a place in the
display arrangement, and it still moves the tiling of AeroSpace.

macOS gives no way to turn a display off while the lid is open. Every public
control changes the brightness, the mirror set, or the sleep state. None of them
removes the display from the list. `pmset`, `displayplacer`, and the display
pane of System Settings all stop short of this.

The capability exists in the SkyLight framework, which is private. Three
functions do the work: `SLSBeginDisplayConfiguration`,
`SLSConfigureDisplayEnabled`, and `SLSCompleteDisplayConfiguration`. A display
that goes through them leaves `CGGetOnlineDisplayList` completely. We measured
this on aqua: with the built-in display off, only the two external monitors
remain in the list.

We therefore accept a dependency on a private framework. `displayctl` finds the
three functions with `dlsym` at run time, instead of a link at build time. A
version of macOS that removes them makes the tool report the problem and make no
change. It does not make the tool fail to build or fail to start.

## Considered options

- **Buy BetterDisplay Pro**, which has the same feature. Rejected: it also
  duplicates MonitorControl, which already handles the brightness of the
  external monitors. Two apps that both drive DDC over the same bus fight each
  other. We would pay for an app and then turn most of it off.
- **Mirror the built-in display onto an external one** and set the brightness to
  zero. This needs no private function. Rejected: the panel stays lit at a low
  level, the display keeps its place in the arrangement, and the resolution of
  the mirror set follows the smallest display.
- **Put a magnet near the lid sensor** to make macOS believe the lid is shut.
  Rejected: it also turns off the internal keyboard and the trackpad, which are
  the reason the lid is open.

## Consequences

- The change applies to the login session only. A restart or a logout always
  brings the panel back, so a mistake cannot leave aqua without a screen.
- The agent refuses to disable the built-in display when it is the only one.
- The agent turns the display back on when it stops, so `launchctl bootout` and
  a reinstall are both safe.
- AeroSpace reassigns its workspaces when a display appears or disappears. The
  tiling therefore moves each time the monitor count changes.
- The agent must hold a connection to the window server, or
  `CGDisplayRegisterReconfigurationCallback` never fires. A registration
  succeeds without the connection, so the failure is silent: the agent starts,
  it sets the correct state one time, and it then ignores every monitor that
  comes or goes. `NSApplication.shared` makes the connection. The activation
  policy is `prohibited`, so the agent stays out of the Dock.
- The install script waits for the label to disappear between the bootout and
  the bootstrap. A bootout returns before the agent stops, and the agent takes a
  moment to turn the display back on first, so an immediate bootstrap fails with
  "Input/output error".
- A change through SkyLight notifies only the process that made it. Another
  process on the same Mac sees no event. A test of the agent therefore needs a
  real reconfiguration, such as a cable event or a change of origin.
- An absent display in `CGGetOnlineDisplayList` has two causes. The tool
  disabled the display, or the window server is in the middle of a change. The
  tool must not read an absent display as "the display is off". It writes a file
  in `/tmp` while it holds the display off. If the display is absent and the
  file is missing, the tool makes no change and looks again a moment later. The
  file and the change end at the same time, because a restart clears both.
- The agent remembers the number of monitors only after the display reaches the
  wanted state. A change that did not happen leaves that number unset, so the
  next look tries again. If the agent remembered the number after a change that
  failed, it would report no change in the set of monitors and leave the panel
  on until the desk changed.
- onyx does not run this agent. The build script, the install script, and
  `.chezmoiignore` all test the hostname.
