-- The last tab. This is the Rex copy of tmux prefix+o
-- (~/.tmux/scripts/switch-last.sh).
--
-- The last_tab action shows the tab that had focus before the current tab.
-- Run it again to go back. If that tab closed, the action shows the tab that
-- had focus before it.
--
-- Rex sends events only to scripts, not to this file. Thus
-- scripts/last-tab-watcher.lua keeps the tab history of each session in
-- $REX_LAST_TAB_DIR/history.json. The default directory is
-- ~/.local/state/rex-last-tab.
--
-- The history is for one session. tmux prefix+o can also go back to a window
-- in a different session. Rex cannot do this, because the app does not tell
-- the server which session it shows.
--
-- To run the action without the key, use `rex do last_tab`.

local HOME = os.getenv("HOME")
local STATE = os.getenv("REX_LAST_TAB_DIR")
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-last-tab")
local HISTORY = STATE .. "/history.json"

local CONFIG_HOME = os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")
local WATCHER = CONFIG_HOME .. "/rex/scripts/last-tab-watcher.lua"

-- read_history returns the tabs of a session, with the newest tab first.
local function read_history(session_id)
  local f = io.open(HISTORY, "r")
  if not f then return {} end
  local data = rex.json.decode(f:read("*a"))
  f:close()
  return data and data.sessions and data.sessions[session_id] or {}
end

local function last_tab(ctx)
  local sid = ctx.session_id
  if not sid then error("last_tab: no session", 0) end
  local view, err = rex.session.view{ session_id = sid }
  if not view then error("last_tab: " .. tostring(err), 0) end

  local open = {}
  for _, w in ipairs(view.windows or {}) do open[w.window_id] = true end
  for _, id in ipairs(read_history(sid)) do
    if id ~= view.active_window_id and open[id] then
      rex.session.focus_window{ session_id = sid, window_id = id }
      return { session_id = sid, window_id = id }
    end
  end
  return nil
end

rex.action{
  name = "last_tab",
  title = "Show Last Tab",
  description = "Show the tab that had focus before the current tab, in the same session.",
  keywords = "last previous recent tab window toggle back switch",
  run = function(ctx) return last_tab(ctx) end,
}

-- Start the watcher each time the server loads this file. If a watcher runs
-- already, the new one exits.
require("background").start({ "--all", WATCHER, "state=" .. STATE })
