-- The watcher of closed tabs. closed_tabs.lua starts this script with
-- `rex do --all` each time the Rex server loads the configuration.
--
-- An event cannot read a tab that closed. When window_closed arrives, the
-- blocks of the tab are gone, and the event gives only the window id. Thus
-- the watcher keeps a copy of the layout of each tab. It updates the copy
-- after each change to a session, and each INTERVAL seconds. When a tab or a
-- session closes, the watcher writes the copy to the log as one entry.
--
-- Rex sends no window_closed for the tabs of a session that is destroyed.
-- Thus session_destroyed writes one entry that holds all tabs of the session.
--
-- For each pane, the copy keeps the directory, the program, and the Claude
-- session that runs in the pane. Claude writes ~/.claude/sessions/<pid>.json
-- with its session id. If the pane runs Claude, the copy types
-- `claude --resume <id>` into the new pane when the tab opens again.
--
-- closed-tabs.sh reads the log and opens an entry again.
--
-- Only one watcher runs on a server. The watcher gives its client the label
-- closed-tabs-watcher, and a new watcher that finds a client with that label
-- exits. To start the watcher again with new code, stop it with
-- `pkill -f closed-tabs-watcher.lua`, then run `rex config reload`.
--
-- To run it by hand:
--   rex do --all ~/.config/rex/scripts/closed-tabs-watcher.lua
-- The tests give other values with these arguments: label=, state=,
-- interval=, claude_sessions=, claude_projects=.

local HOME = os.getenv("HOME")
local LABEL = rex.args.label or "closed-tabs-watcher"
local STATE = rex.args.state
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-closed-tabs")
local LOG = STATE .. "/closed.jsonl"
local LOCK = STATE .. "/.lock"
local CLAUDE_SESSIONS = rex.args.claude_sessions or (HOME .. "/.claude/sessions")
local CLAUDE_PROJECTS = rex.args.claude_projects or (HOME .. "/.claude/projects")
local INTERVAL = tonumber(rex.args.interval) or 5 -- seconds between full copies
local DEBOUNCE = 0.3 -- seconds from the last event of a burst to a copy
local MAX_ENTRIES = 100
local TERMINAL = "com.superlogical.terminal"
local SHELL = "com.superlogical.terminal.shell"

-- cache[session_id] = { label = ..., order = { window, ... }, by_id = { [window_id] = window } }
-- A window is { window_id, label, index, layout, panes }. layout has the
-- format of session.new_window. panes lists the panes for the picker.
local cache = {}
local pending = {}

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

-- claude_of returns the Claude session of a terminal, or nil. Claude can be
-- the foreground process, or the parent of a tool that Claude runs.
local function claude_of(process)
  local chain = { process.foreground }
  for _, p in ipairs(process.ancestors or {}) do chain[#chain + 1] = p end
  for _, p in ipairs(chain) do
    if p and p.name == "claude" and p.pid then
      local text = read_file(CLAUDE_SESSIONS .. "/" .. p.pid .. ".json")
      local info = text and rex.json.decode(text)
      if info and info.sessionId then return info end
    end
  end
  return nil
end

-- resume_command returns the text that brings back Claude in a new pane.
-- Claude keeps a transcript under a directory named for the project path.
-- A session that has no transcript has no messages, so start a new one.
local function resume_command(claude)
  local cwd = claude.cwd or ""
  local transcript = CLAUDE_PROJECTS .. "/" .. cwd:gsub("[^%w]", "-") .. "/" .. claude.sessionId .. ".jsonl"
  if file_exists(transcript) then
    return "claude --resume " .. claude.sessionId .. "\n"
  end
  return "claude\n"
end

-- pane_of returns the block node of the layout and the pane for the picker.
local function pane_of(session_id, block)
  local node = { flavor = block.flavor, label = block.label }
  local pane = { label = block.label, flavor = block.flavor }
  if block.creator_name ~= TERMINAL then return { block = node }, pane end

  local process = rex.block.call(TERMINAL, "process",
    { session_id = session_id, block_id = block.block_id }) or {}
  local fg = process.foreground or {}
  local cwd = fg.cwd
  if not cwd then
    for _, p in ipairs(process.ancestors or {}) do
      if p.cwd then cwd = p.cwd break end
    end
  end
  pane.cmd = fg.name or ""

  local claude = claude_of(process)
  local options = {}
  if claude then
    -- Claude finds a transcript only from the directory where it started.
    cwd = claude.cwd or cwd
    pane.claude_id = claude.sessionId
    pane.claude_name = claude.name
    options.initial_input = resume_command(claude)
  end
  pane.cwd = cwd or HOME
  options.cwd = pane.cwd
  node.flavor = SHELL
  node.options = options
  return { block = node }, pane
end

-- convert returns a layout node in the format of session.new_window. It adds
-- each pane to panes, in layout order.
local function convert(session_id, node, blocks, panes)
  if node.split then
    local s = node.split
    return { split = {
      direction = s.direction,
      ratio = s.ratio,
      before = convert(session_id, s.before, blocks, panes),
      after = convert(session_id, s.after, blocks, panes),
    } }
  end
  local block = blocks[node.block_id]
  if not block then return nil end
  local layout, pane = pane_of(session_id, block)
  panes[#panes + 1] = pane
  return layout
end

local function copy_window(session_id, window, index)
  for _, layer in ipairs(window.layers or {}) do
    -- Floats, such as the status center, do not come back.
    if layer.kind == "tiled" and layer.layout then
      local blocks = {}
      for _, b in ipairs(layer.blocks or {}) do blocks[b.block_id] = b end
      local panes = {}
      local layout = convert(session_id, layer.layout, blocks, panes)
      if layout then
        return {
          window_id = window.window_id,
          label = window.label,
          index = index,
          layout = layout,
          panes = panes,
        }
      end
    end
  end
  return nil
end

-- refresh makes a new copy of one session. If the session does not answer,
-- the old copy stays, because a destroyed session still needs it.
local function refresh(session_id)
  pending[session_id] = nil
  local view = rex.session.view{ session_id = session_id }
  if not view then return end
  local copy = { label = view.label, order = {}, by_id = {} }
  for i, window in ipairs(view.windows or {}) do
    local w = copy_window(session_id, window, i)
    if w then
      copy.order[#copy.order + 1] = w
      copy.by_id[w.window_id] = w
    end
  end
  cache[session_id] = copy
end

local function refresh_all()
  local list = rex.call("session.list")
  if not list then return end
  for _, s in ipairs(list.sessions or {}) do refresh(s.session_id) end
end

-- schedule makes a copy of a session after a burst of events ends.
local function schedule(session_id)
  if not session_id then return end
  if pending[session_id] then pending[session_id]:cancel() end
  pending[session_id] = rex.after(DEBOUNCE, function() refresh(session_id) end)
end

-- lock and unlock protect the log. closed-tabs.sh uses the same lock when
-- it removes an entry.
local function lock()
  for _ = 1, 50 do
    local r = rex.exec({ "mkdir", LOCK })
    if r and r.ok then return end
    rex.sleep(0.05)
  end
  -- A lock that is older than the wait is stale. Take it.
  rex.exec({ "rmdir", LOCK })
  rex.exec({ "mkdir", LOCK })
end

local function unlock() rex.exec({ "rmdir", LOCK }) end

local function strip(window)
  return { label = window.label, index = window.index, layout = window.layout, panes = window.panes }
end

local function record(kind, session_id, label, windows)
  if #windows == 0 then return end
  local now = os.time()
  local entry = {
    id = now .. "-" .. session_id:sub(-8) .. "-" .. math.random(1000, 9999),
    time = now,
    kind = kind,
    session_id = session_id,
    session = label,
    windows = windows,
  }
  local line = rex.json.encode(entry)
  if not line then return end

  lock()
  local f = io.open(LOG, "a")
  if f then
    f:write(line, "\n")
    f:close()
  end
  -- Keep only the newest MAX_ENTRIES entries.
  local lines = {}
  for l in (read_file(LOG) or ""):gmatch("[^\n]+") do lines[#lines + 1] = l end
  if #lines > MAX_ENTRIES then
    local out = io.open(LOG .. ".tmp", "w")
    if out then
      for i = #lines - MAX_ENTRIES + 1, #lines do out:write(lines[i], "\n") end
      out:close()
      os.rename(LOG .. ".tmp", LOG)
    end
  end
  unlock()
end

rex.on("window_closed", function(ctx, ev)
  local s = cache[ctx.session_id]
  local w = s and s.by_id[ev.window_id]
  if not w then return end
  record("tab", ctx.session_id, s.label, { strip(w) })
  s.by_id[ev.window_id] = nil
  for i, x in ipairs(s.order) do
    if x == w then table.remove(s.order, i) break end
  end
end)

rex.on("session_destroyed", function(ctx, ev)
  local sid = ev.session_id or ctx.session_id
  if pending[sid] then pending[sid]:cancel() end
  pending[sid] = nil
  local s = cache[sid]
  cache[sid] = nil
  if not s then return end
  local windows = {}
  for _, w in ipairs(s.order) do windows[#windows + 1] = strip(w) end
  record("session", sid, s.label, windows)
end)

-- These events change what a copy holds.
for _, name in ipairs({
  "session_created", "session_view_changed", "session_label_changed",
  "window_label_changed", "terminal.process_changed", "terminal.pwd_changed",
}) do
  rex.on(name, function(ctx, ev)
    schedule(ctx.session_id or (ev.session and ev.session.session_id))
  end)
end

local clients = rex.call("client.list")
if not clients then rex.stop(1) end
for _, c in ipairs(clients.clients or {}) do
  if c.info and c.info.label == LABEL then rex.stop(0) end
end
rex.call("client.set_label", { label = LABEL })
rex.exec({ "mkdir", "-p", STATE })
math.randomseed(os.time())
refresh_all()
-- A copy also changes without an event, for example when Claude starts a
-- new session after /clear. Thus copy all sessions at each INTERVAL.
rex.every(INTERVAL, refresh_all)
