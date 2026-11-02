-- The tab picker. This is the Rex copy of tmux prefix+f (the tmux-windows tv
-- channel).
--
-- The tab_picker action opens a float with the rex-tabs tv channel. The
-- channel lists the tabs of all sessions, with the state and the last output
-- of their agents, and a preview of the screen. ctrl-f moves between the
-- active tabs, the tabs of held sessions (hold.lua), and the tabs of utility
-- sessions. Enter shows the tab. See scripts/tab-picker.sh.
--
-- To run the action without the key, use `rex do tab_picker`.

local SHELL = "com.superlogical.terminal.shell"

-- The float can run on a host that did not load this file. For example, the
-- Rex of aqua can open the float in a session of onyx. The home directory is
-- not the same on each Mac. Thus a shell finds the script on the host that
-- runs the float. Do not make the path here.
local PICKER = 'exec "${XDG_CONFIG_HOME:-$HOME/.config}/rex/scripts/tab-picker.sh" open'

-- The float fills this fraction of the window.
local WIDTH, HEIGHT = 0.9, 0.85

local function open(ctx)
  local view = assert(rex.session.view{ session_id = ctx.session_id })
  return rex.session.new_layer{
    session_id = ctx.session_id,
    window_id = view.active_window_id,
    bounds = { (1 - WIDTH) / 2, (1 - HEIGHT) / 2, WIDTH, HEIGHT },
    focus = true,
    layout = rex.layout.block{
      flavor = SHELL,
      label = "Tabs",
      options = {
        -- The login shell gives the PATH that finds tv, jq and rex.
        -- tab-picker.sh makes the font of the float smaller, then starts tv.
        -- It asks this client to show the tab that you pick.
        command = { "env", "REX_TABS_CLIENT=" .. (ctx.client_id or ""), "sh", "-c", PICKER },
      },
    },
  }
end

rex.action{
  name = "tab_picker",
  title = "Find a Tab…",
  description = "Pick a tab from all sessions, with the state and the last output of its agent.",
  keywords = "tab window session switch find picker agent claude",
  run = function(ctx) return open(ctx) end,
}
