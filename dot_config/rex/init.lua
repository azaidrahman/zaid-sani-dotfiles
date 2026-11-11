-- Rex configuration.
--
-- This is a trial of Rex as a replacement for tmux. The bindings copy the
-- tmux bindings in ~/.tmux/conf.d/keys.conf, so that the two feel the same.
--
-- Rex does not watch this file. After you change it, run `rex config reload`.
-- To find errors before a reload, run `rex config check`.
--
-- To see all keys, open the Command Palette. It shows the key of each
-- action. Type "custom" to see only the keys of this file (custom.lua).

-- custom.lua must load before the keys and the actions.
require("custom")

-- Keys -----------------------------------------------------------------------
--
-- Bind each key to a named action, not to a function, so that the Command
-- Palette shows it. Bind all keys here, before the actions below. Then the
-- palette search finds each action by its key (custom.lua).
--
-- The tmux prefix is ctrl+space. When a sequence starts with ctrl+space, the
-- key no longer reaches the terminal. Press it two times to send it.

rex.bind("ctrl+space>ctrl+space", "send_prefix")

-- ctrl+] and ctrl+[ show the next tab and the previous tab. These keys do not
-- use the prefix. They no longer reach the terminal, so ctrl+[ does not send
-- Escape to a program.
rex.bind("ctrl+]", "next_tab")
rex.bind("ctrl+[", "previous_tab")

-- cmd+e shows or hides the sidebar, the same as in Obsidian. The app also
-- binds cmd+/ to this action.
rex.bind("cmd+e", "toggle_sidebar")

-- ctrl+h/j/k/l: focus the pane on that side. In nvim, go to the nvim window
-- on that side first (navigator.lua).
rex.bind("ctrl+h", "navigate_left")
rex.bind("ctrl+j", "navigate_down")
rex.bind("ctrl+k", "navigate_up")
rex.bind("ctrl+l", "navigate_right")

-- prefix+- sets the text to the zoomed-out size. prefix+= sets the text back
-- to the default size.
rex.bind("ctrl+space>-", "font_zoom_out")
rex.bind("ctrl+space>=", "font_reset")

-- prefix+u: the status center (usage.lua).
rex.bind("ctrl+space>u", "status_center")

-- prefix+X: open a tab or a session that closed (closed_tabs.lua).
rex.bind("ctrl+space>shift+x", "closed_tabs")

-- prefix+A: restart the Claude session in the pane and resume the same
-- conversation, for example after a Claude Code update (restart_claude.lua).
rex.bind("ctrl+space>shift+a", "restart_claude")

-- prefix+b: hold or release the session (hold.lua).
rex.bind("ctrl+space>b", "toggle_hold")

-- prefix+e: review the changes of a git worktree in tuicr (diff_review.lua).
rex.bind("ctrl+space>e", "diff_review")

-- prefix+f: pick a tab from all sessions (tab_picker.lua).
rex.bind("ctrl+space>f", "tab_picker")

-- prefix+y: edit the commit message or the pull request draft that Claude
-- proposed, in a float (commit_draft.lua).
rex.bind("ctrl+space>y", "commit_draft")

-- prefix+p: pick a Bitbucket PR (bb_prs.lua). tmux keeps this on prefix+B,
-- because tmux uses prefix+p for previous-window.
rex.bind("ctrl+space>p", "bb_prs")

-- prefix+v: special paste. In a pane of a Rex host or an ssh pane, send the
-- clipboard image to the host and paste its path there (special_paste.lua).
-- tmux uses prefix+i, and there you paste the path yourself.
rex.bind("ctrl+space>v", "special_paste")

-- prefix+D: move the focused float into the layout, as a regular pane
-- (dock.lua). tmux has no floats, so this key has no tmux copy.
rex.bind("ctrl+space>shift+d", "dock_float")

-- cmd+z or prefix+d: zen mode. The pane floats in the middle of its tab, over
-- a dark backdrop, with smaller text (zen.lua). tmux uses prefix+z for zen
-- mode, and prefix+d to detach. prefix+Z only zooms the pane, the same as in
-- tmux.
--
-- In the app, cmd+z is Edit > Undo. Undo is off in a terminal pane, and a
-- terminal does not send cmd keys to its program. Thus zen mode can use the
-- key. shift+cmd+z (Redo) stays as it is.
rex.bind("cmd+z", "zen")
rex.bind("ctrl+space>d", "zen")
rex.bind("ctrl+space>shift+z", "zoom_pane")

-- cmd+w does File > Close, as in the app. In zen mode, it leaves zen mode and
-- puts the pane back, so that the pane does not close by mistake (zen.lua).
rex.bind("cmd+w", "close_or_leave_zen")

-- Actions --------------------------------------------------------------------

-- client_action defines an action that asks the app to run one of its own
-- actions. A key bound to the new action shows in the Custom group of the
-- palette. The action of the app keeps its own entry and its own keys.
local function client_action(spec, action, args)
  spec.run = function() rex.client.queue(action, args) end
  rex.action(spec)
end

client_action({
  name = "send_prefix",
  title = "Send Prefix to Terminal",
  description = "Send ctrl+space to the program in the pane.",
  keywords = "prefix ctrl+space send key terminal",
}, "pane.send_key", { key = "ctrl+space" })

client_action({
  name = "next_tab",
  title = "Show Next Tab",
  description = "Show the next tab in the session.",
  keywords = "tab window next",
}, "client.tab.next")

client_action({
  name = "previous_tab",
  title = "Show Previous Tab",
  description = "Show the previous tab in the session.",
  keywords = "tab window previous",
}, "client.tab.previous")

client_action({
  name = "toggle_sidebar",
  title = "Show or Hide Sidebar",
  description = "Show or hide the sidebar, the same as cmd+e in Obsidian.",
  keywords = "sidebar toggle hide show",
}, "client.sidebar.toggle")

client_action({
  name = "zoom_pane",
  title = "Zoom Pane",
  description = "Make the focused pane fill the tab, or restore the layout.",
  keywords = "zoom pane maximize fill restore",
}, "pane.zoom")

client_action({
  name = "font_reset",
  title = "Reset Text Size",
  description = "Set the text back to the default size.",
  keywords = "font size zoom text reset default",
}, "client.font.reset")

-- The default text size is the zoomed-in size. Rex keeps it in Settings, as
-- Terminal Font Size 20 (Workspace.terminalFontPointSize). This file cannot
-- set it.
--
-- Rex cannot set a font size directly. Thus the zoomed-out size is the
-- default size minus ZOOM_STEPS times "Decrease Font Size". One step is 1
-- point, so the zoomed-out size is 12.
local ZOOM_STEPS = 8

rex.action{
  name = "font_zoom_out",
  title = "Zoom Text Out",
  description = "Set the text to the default size minus a fixed number of steps.",
  keywords = "font size zoom text smaller preset",
  run = function()
    rex.client.queue("client.font.reset")
    for _ = 1, ZOOM_STEPS do rex.client.queue("client.font.decrease") end
  end,
}

require("navigator")
require("usage")
require("closed_tabs")
require("restart_claude")
require("hold")
require("diff_review")
require("tab_picker")
require("commit_draft")
require("bb_prs")
require("dock")
require("zen")
require("special_paste")

-- Keep a copy of the tabs of each host for the Alfred workflow Rex Tabs
-- (scripts/remote-tabs-watcher.lua). If a watcher runs already, the new one
-- exits.
require("background").start({
  (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config"))
    .. "/rex/scripts/remote-tabs-watcher.lua",
})
