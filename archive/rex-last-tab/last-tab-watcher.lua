-- The watcher of the tab history. last_tab.lua starts this script with
-- `rex do` each time the Rex server loads the configuration.
--
-- The watcher keeps one list of the tabs that the app showed, for all
-- sessions and all hosts, with the oldest tab first. The list works like the
-- jump list of vim. The tab_back and tab_forward actions move back and
-- forward in the list, and they do not change the order of the list.
--
-- When you show a tab in a different way, for example with a click, with
-- ctrl+], or with the sidebar, the watcher moves the tab that you left to the
-- end of the list. Then it puts the new tab after it. Thus tab_back always
-- shows the tab that you left. When a tab closes, the watcher removes it.
--
-- The tab that the app shows comes from two values:
--   1. The session. No server knows which session the app shows. The app
--      keeps it in its settings, as Workspace.lastFocusedSession. The
--      watcher reads that value each TICK seconds. This value is not a part
--      of the Rex API, so a new version of the app can change it.
--   2. The active tab of that session. The server of the session knows it.
--      The watcher starts tab-feed.lua for this server and for each host
--      that `rex hosts` lists. Each feed sends the changes of its server.
-- The two values change at different times. Thus a tab goes into the list
-- only after the app shows it for two ticks.
--
-- The watcher writes the list to history.json after each change. Each entry
-- is "SESSION/WINDOW". The list has a number, seq. The watcher adds 1 to seq
-- each time that the order of the list changes. The actions write the tab
-- that they show to nav.json, with the seq of the list. When the app shows
-- that tab and seq did not change, the watcher keeps the order of the list.
--
-- Only one watcher runs on a server. The watcher gives its client the label
-- last-tab-watcher, and a new watcher that finds a client with that label
-- exits. To start the watcher again with new code, stop it with
-- `pkill -f last-tab-watcher.lua`, then run `rex config reload`.
--
-- To run it by hand:
--   rex do ~/.config/rex/scripts/last-tab-watcher.lua
-- The tests give other values with these arguments: label=, state=, rex=,
-- hosts= (labels, with commas between them), focus= (a file that holds the
-- value of the app setting, as JSON), tick=.

local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)") or "./"

local HOME = os.getenv("HOME")
local LABEL = rex.args.label or "last-tab-watcher"
local STATE = rex.args.state
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-last-tab")
local FILE = STATE .. "/history.json"
local NAV = STATE .. "/nav.json"
-- background.lua gives the rex binary of the server in REX_BIN.
local REX = rex.args.rex or os.getenv("REX_BIN") or "rex"
local FEED = dir .. "tab-feed.lua"
local FOCUS = rex.args.focus
local TICK = tonumber(rex.args.tick) or 0.25 -- seconds between reads of the app setting
local CHECK = 5   -- seconds between checks of the feeds
local RETRY = 30  -- seconds from a failure of a feed to a new start
local FULL = 8    -- ticks between full reads of the app setting
local MAX_TABS = 30

-- history = { tabs = { "SESSION/WINDOW", ... }, current = entry, seq = n }
local history = { tabs = {}, seq = 0 }

-- servers[name] = { sessions = { [sid] = { active = wid, windows = { [wid] = true } } },
-- ready = bool, handle = ..., buf = "", ended = time }. The name of this
-- server is "".
local servers = {}

local function decode(text)
  local ok, data = pcall(rex.json.decode, text or "")
  if ok and type(data) == "table" then return data end
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return decode(text)
end

-- save writes a new file and moves it into place, so that the action never
-- reads half a file.
local function save()
  local text = rex.json.encode(history)
  if not text then return end
  local tmp = FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(text, "\n")
  f:close()
  os.rename(tmp, FILE)
end

local function remove(list, entry)
  for i = #list, 1, -1 do
    if list[i] == entry then table.remove(list, i) end
  end
end

local function put_last(list, entry)
  remove(list, entry)
  list[#list + 1] = entry
  while #list > MAX_TABS do table.remove(list, 1) end
end

-- The session that the app shows ---------------------------------------------

local focus = { raw = nil, sid = nil, ticks = 0 }

-- read_focus reads Workspace.lastFocusedSession. `defaults read` is fast, but
-- it prints only the start and the end of the value. The end has the end of
-- the session ID. Thus a full read runs only when that output changes, and
-- each FULL ticks.
local function read_focus()
  if FOCUS then
    local data = read_json(FOCUS)
    focus.sid = data and data.sessionID
    return
  end
  local r = rex.exec({ "/usr/bin/defaults", "read", "com.superlogical.rex",
    "Workspace.lastFocusedSession" }, { timeout = 2 })
  local raw = r and r.ok and r.stdout or ""
  focus.ticks = focus.ticks + 1
  if raw == focus.raw and focus.ticks < FULL then return end
  focus.raw, focus.ticks = raw, 0
  local full = rex.exec({ "/bin/sh", "-c",
    "/usr/bin/defaults export com.superlogical.rex - "
      .. "| /usr/bin/plutil -extract 'Workspace\\.lastFocusedSession' raw -o - - "
      .. "| /usr/bin/base64 -d" }, { timeout = 2 })
  local data = full and full.ok and decode(full.stdout)
  focus.sid = data and data.sessionID
end

-- The tabs of each server -----------------------------------------------------

local function find_session(sid)
  for _, srv in pairs(servers) do
    local s = srv.sessions[sid]
    if s then return s end
  end
end

local function all_ready()
  for _, srv in pairs(servers) do
    if not srv.ready then return false end
  end
  return true
end

-- prune removes the tabs that closed. A session that no server knows can be
-- on a host that does not answer. Thus the watcher removes it only when all
-- feeds are ready.
local function prune()
  local changed = false
  local complete = all_ready()
  for i = #history.tabs, 1, -1 do
    local sid, wid = history.tabs[i]:match("^(.-)/(.+)$")
    local s = sid and find_session(sid)
    if not sid or (s and not s.windows[wid]) or (not s and complete) then
      if history.current == history.tabs[i] then history.current = nil end
      table.remove(history.tabs, i)
      changed = true
    end
  end
  if changed then save() end
end

local function on_message(srv, msg)
  if msg.type == "session" and msg.session_id then
    local windows = {}
    for _, w in ipairs(msg.windows or {}) do windows[w] = true end
    srv.sessions[msg.session_id] = { active = msg.active, windows = windows }
  elseif msg.type == "active" and msg.session_id and msg.window_id then
    local s = srv.sessions[msg.session_id] or { windows = {} }
    s.active = msg.window_id
    s.windows[msg.window_id] = true
    srv.sessions[msg.session_id] = s
  elseif msg.type == "gone" and msg.session_id then
    srv.sessions[msg.session_id] = nil
  elseif msg.type == "ready" then
    srv.ready = true
  end
  prune()
end

local function start(name, pid)
  local srv = servers[name] or { sessions = {} }
  servers[name] = srv
  srv.buf, srv.ready = "", false
  local argv = { REX, "--autostart=false", "--timeout", "10s" }
  if name ~= "" then
    argv[#argv + 1] = "-S"
    argv[#argv + 1] = name
  end
  for _, a in ipairs({ "do", "--all", FEED, "parent=" .. pid }) do argv[#argv + 1] = a end
  srv.handle = rex.exec.start(argv, {
    detach = true,
    stderr = false,
    stdout = function(piece)
      srv.buf = srv.buf .. piece
      for line in srv.buf:gmatch("([^\n]*)\n") do
        local msg = decode(line)
        if msg then on_message(srv, msg) end
      end
      srv.buf = srv.buf:match("[^\n]*$")
    end,
  })
  if not srv.handle then srv.ended = os.time() end
end

local function hosts()
  if rex.args.hosts then
    local list = {}
    for h in tostring(rex.args.hosts):gmatch("[^,]+") do list[#list + 1] = h end
    return list
  end
  return rex.servers()
end

local function check(pid)
  local now = os.time()
  local wanted = { [""] = true }
  for _, h in ipairs(hosts()) do wanted[h] = true end
  for name in pairs(wanted) do
    local srv = servers[name]
    if srv and srv.handle and not srv.handle:running() then
      srv.handle:wait(0)
      srv.handle, srv.ended = nil, now
    end
    if not srv or (not srv.handle and now - (srv.ended or 0) >= RETRY) then start(name, pid) end
  end
  for name, srv in pairs(servers) do
    if not wanted[name] then
      if srv.handle then srv.handle:kill() end
      servers[name] = nil
    end
  end
end

-- The list --------------------------------------------------------------------

local function visit(entry)
  local nav = read_json(NAV)
  if not (nav and nav.seq == history.seq and nav.key == entry) then
    if history.current then put_last(history.tabs, history.current) end
    put_last(history.tabs, entry)
    history.seq = history.seq + 1
  end
  history.current = entry
  save()
end

-- tick records the tab that the app shows, after the app shows it for two
-- ticks.
local pending
local function tick()
  read_focus()
  local s = focus.sid and find_session(focus.sid)
  local entry = s and s.active and (focus.sid .. "/" .. s.active)
  if not entry or entry == history.current then
    pending = nil
  elseif entry ~= pending then
    pending = entry
  else
    pending = nil
    visit(entry)
  end
end

-- Start -----------------------------------------------------------------------

local clients = rex.call("client.list")
if not clients then rex.stop(1) end
for _, c in ipairs(clients.clients or {}) do
  if c.info and c.info.label == LABEL then rex.stop(0) end
end
rex.call("client.set_label", { label = LABEL })
rex.exec({ "mkdir", "-p", STATE })

-- Keep the list of the last watcher. An older watcher wrote a list for each
-- session. Do not use it. Add 1 to seq, so that an old entry in nav.json does
-- not match.
local old = read_json(FILE)
if old and type(old.tabs) == "table" then
  for _, e in ipairs(old.tabs) do
    if type(e) == "string" then history.tabs[#history.tabs + 1] = e end
  end
  history.seq = (tonumber(old.seq) or 0) + 1
end
save()

-- The feeds stop when this process stops. The parent of the shell is this
-- process.
local ps = rex.exec({ "/bin/sh", "-c", "echo $PPID" })
local pid = ps and ps.ok and ps.stdout:match("%d+")
if not pid then rex.stop(1) end

check(pid)
rex.every(CHECK, function() check(pid) end)
rex.every(TICK, tick)
