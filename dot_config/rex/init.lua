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

-- prefix+u: the status center (usage.lua).
require("usage")
rex.bind("ctrl+space>u", "status_center")
