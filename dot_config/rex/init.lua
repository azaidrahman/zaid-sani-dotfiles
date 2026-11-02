-- Rex configuration.
--
-- This is a trial of Rex as a replacement for tmux. The bindings copy the
-- tmux bindings in ~/.tmux/conf.d/keys.conf, so that the two feel the same.
--
-- Rex does not watch this file. After you change it, run `rex config reload`.
-- To find errors before a reload, run `rex config check`.

-- The tmux prefix is ctrl+space. When a sequence starts with ctrl+space, the
-- key no longer reaches the terminal. Press it two times to send it.
rex.bind("ctrl+space>ctrl+space", "pane.send_key", { key = "ctrl+space" })

-- ctrl+] and ctrl+[ show the next tab and the previous tab. These keys do not
-- use the prefix. They no longer reach the terminal, so ctrl+[ does not send
-- Escape to a program.
rex.bind("ctrl+]", "client.tab.next")
rex.bind("ctrl+[", "client.tab.previous")

-- cmd+e shows or hides the sidebar, the same as in Obsidian. The app also
-- binds cmd+/ to this action.
rex.bind("cmd+e", "client.sidebar.toggle")

-- ctrl+h, ctrl+j, ctrl+k, and ctrl+l focus the pane on the left, below, above,
-- or on the right. This copies vim-tmux-navigator in tmux.
--
-- If the foreground program of the pane is in NAVIGATOR_PROGRAMS, the key goes
-- to that program. nvim then moves between its own windows. At the edge, nvim
-- runs `rex focus` (nvim/lua/zaid/plugins/vim-tmux-navigator.lua). tmux is in
-- the list, so that tmux in a Rex pane still gets the keys.
--
-- A function binding that returns false sends the key to the terminal.
local NAVIGATOR_PROGRAMS = { nvim = true, vim = true, view = true, fzf = true, tmux = true }

local function navigate(direction)
  return function(ctx)
    local process = rex.block.call("com.superlogical.terminal", "process",
      { block_id = ctx.block_id }) or {}
    if NAVIGATOR_PROGRAMS[(process.foreground or {}).name] then
      return false
    end
    rex.session.focus_direction{ session_id = ctx.session_id, direction = direction }
    return true
  end
end

rex.bind("ctrl+h", navigate("left"))
rex.bind("ctrl+j", navigate("down"))
rex.bind("ctrl+k", navigate("up"))
rex.bind("ctrl+l", navigate("right"))

-- The default text size is the zoomed-in size. Rex keeps it in Settings, as
-- Terminal Font Size 20 (Workspace.terminalFontPointSize). This file cannot
-- set it. prefix+- sets the text to the zoomed-out size. prefix+= sets the
-- text back to the default size.
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
rex.bind("ctrl+space>-", "font_zoom_out")
rex.bind("ctrl+space>=", "client.font.reset")

-- prefix+u: the status center (usage.lua).
require("usage")
rex.bind("ctrl+space>u", "status_center")

-- prefix+X: open a tab or a session that closed (closed_tabs.lua).
require("closed_tabs")
rex.bind("ctrl+space>shift+x", "closed_tabs")

-- prefix+A: restart the Claude session in the pane and resume the same
-- conversation, for example after a Claude Code update (restart_claude.lua).
require("restart_claude")
rex.bind("ctrl+space>shift+a", "restart_claude")

-- prefix+b: hold or release the session (hold.lua).
require("hold")
rex.bind("ctrl+space>b", "toggle_hold")

-- prefix+e: review the changes of a git worktree in tuicr (diff_review.lua).
require("diff_review")
rex.bind("ctrl+space>e", "diff_review")

-- prefix+f: pick a tab from all sessions (tab_picker.lua).
require("tab_picker")
rex.bind("ctrl+space>f", "tab_picker")

-- prefix+o: show the tab that had focus before the current tab
-- (last_tab.lua).
require("last_tab")
rex.bind("ctrl+space>o", "last_tab")

-- prefix+y: edit the commit message or the pull request draft that Claude
-- proposed, in a float (commit_draft.lua).
require("commit_draft")
rex.bind("ctrl+space>y", "commit_draft")

-- prefix+D: move the focused float into the layout, as a regular pane
-- (dock.lua). tmux has no floats, so this key has no tmux copy.
require("dock")
rex.bind("ctrl+space>shift+d", "dock_float")

-- Keep a copy of the tabs of each host for the Alfred workflow Rex Tabs
-- (scripts/remote-tabs-watcher.lua). If a watcher runs already, the new one
-- exits.
require("background").start({
  (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config"))
    .. "/rex/scripts/remote-tabs-watcher.lua",
})
