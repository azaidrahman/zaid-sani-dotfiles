-- Closed tabs. This is the Rex copy of tmux prefix+X.
--
-- scripts/closed-tabs-watcher.lua keeps a log of the tabs and the sessions
-- that closed. The closed_tabs action opens a float with the rex-closed tv
-- channel. The channel shows the log, newest first. Enter opens the tab or
-- the session again, with the same panes and directories, and resumes the
-- Claude conversations. See scripts/closed-tabs.sh.
--
-- To run the action without the key, use `rex do closed_tabs`.

local SHELL = "com.superlogical.terminal.shell"
local CONFIG_HOME = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
local WATCHER = CONFIG_HOME .. "/rex/scripts/closed-tabs-watcher.lua"

-- The float fills this fraction of the window.
local WIDTH, HEIGHT = 0.8, 0.75

-- Start the watcher each time the server loads this file. If a watcher runs
-- already, the new one exits.
require("background").start({ "--all", WATCHER })

local function open(ctx)
  local view = assert(rex.session.view{ session_id = ctx.session_id })
  return rex.session.new_layer{
    session_id = ctx.session_id,
    window_id = view.active_window_id,
    bounds = { (1 - WIDTH) / 2, (1 - HEIGHT) / 2, WIDTH, HEIGHT },
    focus = true,
    layout = rex.layout.block{
      flavor = SHELL,
      label = "Closed tabs",
      options = {
        -- The login shell gives the PATH that finds tv, jq and rex.
        -- closed-tabs.sh asks this client to show the tab that opens.
        command = { "env", "REX_CLOSED_CLIENT=" .. (ctx.client_id or ""), "tv", "rex-closed" },
      },
    },
  }
end

rex.action{
  name = "closed_tabs",
  title = "Reopen a Closed Tab…",
  description = "Pick a tab or a session that closed, and open it again with its panes, directories and Claude sessions.",
  keywords = "closed reopen restore undo recent tab window session",
  run = function(ctx) return open(ctx) end,
}
