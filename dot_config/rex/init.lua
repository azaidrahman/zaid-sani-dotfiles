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

-- Keep a copy of the tabs of each host for the Alfred workflow Rex Tabs
-- (scripts/remote-tabs-watcher.lua). If a watcher runs already, the new one
-- exits.
require("background").start({
  (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config"))
    .. "/rex/scripts/remote-tabs-watcher.lua",
})
