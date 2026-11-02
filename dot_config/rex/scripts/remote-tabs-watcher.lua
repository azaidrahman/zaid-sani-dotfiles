-- The watcher of the tabs on other hosts. init.lua starts this script with
-- `rex do` each time the Rex server loads the configuration. It runs on each
-- Mac, for example on aqua for the tabs of onyx, and on onyx for the tabs of
-- aqua.
--
-- The Alfred workflow Rex Tabs lists the tabs of this Mac and of each host
-- that `rex hosts` lists. Over a relay of the tailnet, each call to a host
-- takes about 30 ms, and a list of the tabs takes about 400 ms. Thus this
-- script keeps a copy of the tabs of each host in STATE/<host>.json. Alfred
-- reads the copy, and does not wait for the host.
--
-- For each host, this script starts host-tabs-watcher.lua with
-- `rex -S HOST do --all`. That script writes the copy after each change on
-- the host. If it stops with an error, for example because the host sleeps,
-- this script writes the error to the copy. Alfred then shows that the host
-- is not reachable, and does not wait for it. This script starts the host
-- watcher again after RETRY seconds.
--
-- Only one watcher runs on a server. The watcher gives its client the label
-- remote-tabs-watcher, and a new watcher that finds a client with that label
-- exits. To start the watcher again with new code, stop it with
-- `pkill -f tabs-watcher.lua`, then run `rex config reload`.
--
-- To run it by hand:
--   rex do ~/.config/rex/scripts/remote-tabs-watcher.lua
-- The tests give other values with these arguments: label=, state=, rex=,
-- hosts= (labels or addresses, with commas between them), check=, retry=,
-- heartbeat=.

local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)") or "./"
local tabs = dofile(dir .. "tabs.lua")

local HOME = os.getenv("HOME")
local LABEL = rex.args.label or "remote-tabs-watcher"
local STATE = rex.args.state
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-remote-tabs")
-- background.lua gives the rex binary of the server in REX_BIN.
local REX = rex.args.rex or os.getenv("REX_BIN") or "rex"
local CHILD = dir .. "host-tabs-watcher.lua"
local CHECK = tonumber(rex.args.check) or 5  -- seconds between checks of the host watchers
local RETRY = tonumber(rex.args.retry) or 30 -- seconds from a failure to a new start
local HEARTBEAT = rex.args.heartbeat

-- children[host] = { handle = ..., err = ..., ended = ... }
local children = {}

-- copy_path gives the file of the copy of a host. The Alfred workflow makes
-- the same name with `tr -c 'A-Za-z0-9.-' '_'`.
local function copy_path(host)
  return STATE .. "/" .. host:gsub("[^%w%.%-]", "_") .. ".json"
end

local function hosts()
  if rex.args.hosts then
    local list = {}
    for h in tostring(rex.args.hosts):gmatch("[^,]+") do list[#list + 1] = h end
    return list
  end
  return rex.servers()
end

-- last_error gives the last line of the output that starts with "Error:".
local function last_error(text)
  local found
  for line in (text or ""):gmatch("[^\n]+") do
    local msg = line:match("^Error: (.*)")
    if msg then found = msg end
  end
  return found
end

local function start(host, pid)
  local c = { err = "" }
  local argv = {
    REX, "--autostart=false", "--timeout", "10s", "-S", host, "do", "--all", CHILD,
    "out=" .. copy_path(host), "server=" .. host, "parent=" .. pid,
  }
  if HEARTBEAT then argv[#argv + 1] = "heartbeat=" .. HEARTBEAT end
  c.handle = rex.exec.start(argv, {
    detach = true,
    stdout = false,
    -- Keep only the end of the output, so a long run does not grow it.
    stderr = function(piece) c.err = (c.err .. piece):sub(-4000) end,
  })
  if not c.handle then c.ended = os.time() end
  children[host] = c
end

local function check(pid)
  local now = os.time()
  local wanted = {}
  for _, host in ipairs(hosts()) do
    wanted[host] = true
    local c = children[host]
    if c and c.handle and not c.handle:running() then
      local r = c.handle:wait(0)
      -- Status 0 means that the host watcher stopped by itself, without an
      -- error. Any other status is a failure.
      if not r or r.code ~= 0 then
        tabs.save(copy_path(host), {
          server = host,
          time = now,
          error = last_error(c.err) or ("the watcher stopped with status " .. tostring(r and r.code)),
          tabs = {},
        })
      end
      c.handle = nil
      c.ended = now
    end
    if not c or (not c.handle and now - c.ended >= RETRY) then start(host, pid) end
  end
  -- Stop the watcher of a host that `rex hosts` no longer lists.
  for host, c in pairs(children) do
    if not wanted[host] then
      if c.handle then c.handle:kill() end
      children[host] = nil
      os.remove(copy_path(host))
    end
  end
end

local clients = rex.call("client.list")
if not clients then rex.stop(1) end
for _, c in ipairs(clients.clients or {}) do
  if c.info and c.info.label == LABEL then rex.stop(0) end
end
rex.call("client.set_label", { label = LABEL })
rex.exec({ "mkdir", "-p", "-m", "700", STATE })

-- The host watchers stop when this process stops. The parent of the shell
-- is this process.
local ps = rex.exec({ "/bin/sh", "-c", "echo $PPID" })
local pid = ps and ps.ok and ps.stdout:match("%d+")
if not pid then rex.stop(1) end

check(pid)
rex.every(CHECK, function() check(pid) end)
