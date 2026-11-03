-- The tab history. tab_back is the Rex copy of tmux prefix+o
-- (~/.tmux/scripts/switch-last.sh). tab_forward has no tmux copy.
--
-- The tab_back action shows the tab that you left, in any session and on any
-- host. Run it again to go back one more tab. The tab_forward action goes
-- forward again, to the newer tabs. This works like ctrl+o and ctrl+i in vim.
-- ctrl+] and ctrl+[ are different: they show the next tab and the previous
-- tab in the order of the tab bar.
--
-- Rex sends events only to scripts, not to this file. Thus
-- scripts/last-tab-watcher.lua keeps the tab history in
-- $REX_LAST_TAB_DIR/history.json. The default directory is
-- ~/.local/state/rex-last-tab. The watcher file tells how the list works.
--
-- The actions ask the app to show the tab, with the session.select action of
-- the app. Do not use rex.session.focus_window for this. It changes the active
-- tab on the server, but the Mac app does not show that tab. If no app is
-- connected, for example in the tests, the actions only return the tab.
--
-- To run an action without the key, use `rex do tab_back` or
-- `rex do tab_forward`.

local HOME = os.getenv("HOME")
local STATE = os.getenv("REX_LAST_TAB_DIR")
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-last-tab")
local HISTORY = STATE .. "/history.json"
local NAV = STATE .. "/nav.json"

local CONFIG_HOME = os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")
local WATCHER = CONFIG_HOME .. "/rex/scripts/last-tab-watcher.lua"

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(rex.json.decode, text)
  if ok and type(data) == "table" then return data end
end

-- write_nav records the tab that an action shows. The watcher reads it
-- (last-tab-watcher.lua).
local function write_nav(entry)
  local text = rex.json.encode(entry)
  if not text then return end
  local tmp = NAV .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(text, "\n")
  f:close()
  os.rename(tmp, NAV)
end

-- has_app tells if an app is connected to the server. A key press runs the
-- action for an app. `rex do` sends the client action to the app, if only one
-- app is connected.
local function has_app()
  local list = rex.call("client.list")
  for _, c in ipairs(list and list.clients or {}) do
    if c.info and c.info.kind == "app" then return true end
  end
  return false
end

local function index_of(list, entry)
  for i, v in ipairs(list) do
    if v == entry then return i end
  end
end

-- step shows the tab before (dir = -1) or after (dir = 1) the current tab in
-- the history.
local function step(dir)
  local h = read_json(HISTORY)
  if not h or type(h.tabs) ~= "table" then return nil end
  local target = h.tabs[(index_of(h.tabs, h.current) or (#h.tabs + 1)) + dir]
  if not target then return nil end
  local sid, wid = target:match("^(.-)/(.+)$")
  if not sid then return nil end

  write_nav({ seq = h.seq, key = target })
  if has_app() then
    rex.client.queue("session.select", { session_id = sid, window_id = wid })
  end
  return { session_id = sid, window_id = wid }
end

rex.action{
  name = "tab_back",
  title = "Go Back to the Last Tab",
  description = "Show the tab that you left, in any session. Run it again to go back more tabs.",
  keywords = "last previous recent tab window session history back older switch",
  run = function() return step(-1) end,
}

rex.action{
  name = "tab_forward",
  title = "Go Forward a Tab",
  description = "After tab_back, show the newer tab again, in any session.",
  keywords = "next recent tab window session history forward newer switch",
  run = function() return step(1) end,
}

-- Start the watcher each time the server loads this file. If a watcher runs
-- already, the new one exits.
require("background").start({ WATCHER, "state=" .. STATE })
