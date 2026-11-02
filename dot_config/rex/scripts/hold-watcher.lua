-- The watcher of held sessions. hold.lua starts this script with
-- `rex do --all` each time the Rex server loads the configuration.
--
-- An agent can rename a session, and the new label has no "[HOLD] " marker.
-- When a session in the hold list gets a label without the marker, the
-- watcher puts the marker back. When a session is destroyed, the watcher
-- removes it from the list. At start, the watcher does both for all
-- sessions, because they can change while it does not run.
--
-- Only one watcher runs on a server. The watcher gives its client the label
-- hold-watcher, and a new watcher that finds a client with that label exits.
-- To start the watcher again with new code, stop it with
-- `pkill -f hold-watcher.lua`, then run `rex config reload`.
--
-- To run it by hand:
--   rex do --all ~/.config/rex/scripts/hold-watcher.lua
-- The tests give other values with these arguments: label=, state=.

local HOME = os.getenv("HOME")
local LABEL = rex.args.label or "hold-watcher"
local STATE = rex.args.state
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-hold")
local LIST = STATE .. "/held"
local PREFIX = "[HOLD] "
local MAX_LABEL = 128

local function read_list()
  local ids = {}
  local f = io.open(LIST, "r")
  if not f then return ids end
  for line in f:lines() do
    if line ~= "" then ids[#ids + 1] = line end
  end
  f:close()
  return ids
end

local function write_list(ids)
  local tmp = LIST .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  for _, id in ipairs(ids) do f:write(id, "\n") end
  f:close()
  os.rename(tmp, LIST)
end

local function contains(ids, id)
  for _, x in ipairs(ids) do
    if x == id then return true end
  end
  return false
end

local function mark(session_id, label)
  if label:sub(1, #PREFIX) == PREFIX then return end
  rex.session.set_label{
    session_id = session_id,
    label = PREFIX .. label:sub(1, MAX_LABEL - #PREFIX),
  }
end

rex.on("session_label_changed", function(ctx, ev)
  local sid = ctx.session_id
  if sid and contains(read_list(), sid) then mark(sid, ev.label or "") end
end)

rex.on("session_destroyed", function(ctx, ev)
  local sid = ev.session_id or ctx.session_id
  local ids = read_list()
  if not contains(ids, sid) then return end
  local rest = {}
  for _, id in ipairs(ids) do
    if id ~= sid then rest[#rest + 1] = id end
  end
  write_list(rest)
end)

local clients = rex.call("client.list")
if not clients then rex.stop(1) end
for _, c in ipairs(clients.clients or {}) do
  if c.info and c.info.label == LABEL then rex.stop(0) end
end
rex.call("client.set_label", { label = LABEL })

local list = rex.call("session.list")
if list then
  local ids, alive, kept = read_list(), {}, {}
  for _, s in ipairs(list.sessions or {}) do
    alive[s.session_id] = true
    if contains(ids, s.session_id) then mark(s.session_id, s.label or "") end
  end
  for _, id in ipairs(ids) do
    if alive[id] then kept[#kept + 1] = id end
  end
  if #kept ~= #ids then write_list(kept) end
end
