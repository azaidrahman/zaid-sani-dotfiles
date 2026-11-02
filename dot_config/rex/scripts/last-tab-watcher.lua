-- The watcher of the tab history. last_tab.lua starts this script with
-- `rex do --all` each time the Rex server loads the configuration.
--
-- For each session, the watcher keeps a list of the tabs that had focus, with
-- the newest tab first. When a different tab becomes active, the watcher
-- moves that tab to the start of the list. When a tab closes, the watcher
-- removes it. The watcher writes all lists to history.json after each change.
-- The last_tab action reads that file.
--
-- When the watcher starts, it reads the file of the last watcher. It keeps
-- the tabs that are still open, and it puts the active tab of each session
-- first.
--
-- Only one watcher runs on a server. The watcher gives its client the label
-- last-tab-watcher, and a new watcher that finds a client with that label
-- exits. To start the watcher again with new code, stop it with
-- `pkill -f last-tab-watcher.lua`, then run `rex config reload`.
--
-- To run it by hand:
--   rex do --all ~/.config/rex/scripts/last-tab-watcher.lua
-- The tests give other values with these arguments: label=, state=.

local HOME = os.getenv("HOME")
local LABEL = rex.args.label or "last-tab-watcher"
local STATE = rex.args.state
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-last-tab")
local FILE = STATE .. "/history.json"
local MAX_TABS = 20 -- the longest list for one session

-- history[session_id] = { window_id, ... }, with the newest tab first.
local history = {}

-- save writes a new file and moves it into place, so that the action never
-- reads half a file.
local function save()
  local text = rex.json.encode({ sessions = history })
  if not text then return end
  local tmp = FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(text, "\n")
  f:close()
  os.rename(tmp, FILE)
end

local function remove(list, id)
  for i = #list, 1, -1 do
    if list[i] == id then table.remove(list, i) end
  end
end

local function put_first(list, id)
  remove(list, id)
  table.insert(list, 1, id)
  while #list > MAX_TABS do table.remove(list) end
end

rex.on("active_window_changed", function(ctx, ev)
  local sid = ctx.session_id or ev.session_id
  if not sid or not ev.window_id then return end
  local list = history[sid] or {}
  if list[1] == ev.window_id then return end
  put_first(list, ev.window_id)
  history[sid] = list
  save()
end)

rex.on("window_closed", function(ctx, ev)
  local list = history[ctx.session_id or ev.session_id]
  if not list then return end
  remove(list, ev.window_id)
  save()
end)

rex.on("session_destroyed", function(ctx, ev)
  local sid = ev.session_id or ctx.session_id
  if not history[sid] then return end
  history[sid] = nil
  save()
end)

local clients = rex.call("client.list")
if not clients then rex.stop(1) end
for _, c in ipairs(clients.clients or {}) do
  if c.info and c.info.label == LABEL then rex.stop(0) end
end
rex.call("client.set_label", { label = LABEL })
rex.exec({ "mkdir", "-p", STATE })

-- seed makes the first lists from the file of the last watcher. If an event
-- made the list of a session already, that list stays.
local function seed()
  local old = {}
  local f = io.open(FILE, "r")
  if f then
    local data = rex.json.decode(f:read("*a"))
    f:close()
    old = data and data.sessions or {}
  end

  local list = rex.call("session.list")
  for _, s in ipairs(list and list.sessions or {}) do
    local view = not history[s.session_id] and rex.session.view{ session_id = s.session_id }
    if view then
      local open, kept = {}, {}
      for _, w in ipairs(view.windows or {}) do open[w.window_id] = true end
      for _, id in ipairs(old[s.session_id] or {}) do
        if open[id] then kept[#kept + 1] = id end
      end
      if view.active_window_id then put_first(kept, view.active_window_id) end
      history[s.session_id] = kept
    end
  end
  save()
end

-- While the top level of the script runs, the script is not attached to the
-- sessions yet, and session.view fails. A timer runs after the attach.
rex.after(0, seed)
