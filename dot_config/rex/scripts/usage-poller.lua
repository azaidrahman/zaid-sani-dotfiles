-- The poller of the status center. usage.lua starts this script with
-- `rex do` each time the Rex server loads the configuration.
--
-- Each minute, if a Rex app shows a session, the poller runs
-- `usage.sh --refresh`. That command fetches the Claude usage and writes it
-- to the cache. The float then draws the cache at once, and does not wait for
-- `claude -p /usage`.
--
-- Only one poller runs on a server. The poller gives its client the label
-- usage-poller, and a new poller that finds a client with that label exits.
-- Thus a reload does not replace a poller that runs. To start the poller
-- again with new code, stop it with `pkill -f usage-poller.lua`, then run
-- `rex config reload`. The poller stops when it cannot reach the server.
--
-- The poller writes one line for each fetch to the log,
-- ~/Library/Logs/rex-usage-poller.log. When the log is larger than 1 MB, it
-- becomes rex-usage-poller.log.1 and a new log starts.
--
-- To run it by hand:
--   rex do ~/.config/rex/scripts/usage-poller.lua script=$HOME/.config/rex/scripts/usage.sh
-- Add log=PATH to write the log to another file.

local LABEL = "usage-poller"
local INTERVAL = 60 -- seconds from one fetch to the next
local TIMEOUT = 30  -- seconds that one fetch can take
local LOG = rex.args.log or (os.getenv("HOME") .. "/Library/Logs/rex-usage-poller.log")
local LOG_MAX_BYTES = 1024 * 1024

-- log writes one line with the time to the log.
local function log(message)
  local f = io.open(LOG, "a")
  if not f then return end
  if f:seek("end") > LOG_MAX_BYTES then
    f:close()
    os.rename(LOG, LOG .. ".1")
    f = io.open(LOG, "a")
    if not f then return end
  end
  f:write(os.date("%Y-%m-%d %H:%M:%S "), message, "\n")
  f:close()
end

local script = rex.args.script
if not script then
  log("not started: give the path of usage.sh as script=PATH")
  rex.stop(2)
end

local function clients()
  local list = rex.call("client.list")
  return list and list.clients
end

-- has_label returns true when a client in the list has the label of the
-- poller.
local function has_label(list)
  for _, client in ipairs(list) do
    if client.info and client.info.label == LABEL then return true end
  end
  return false
end

-- app_shows_session returns true when a Rex app is attached to a session.
local function app_shows_session(list)
  for _, client in ipairs(list) do
    local info = client.info or {}
    if info.kind == "app" and #(client.session_ids or {}) > 0 then
      return true
    end
  end
  return false
end

-- last_line returns the last line of text that is not empty.
local function last_line(text)
  local last = ""
  for line in (text or ""):gmatch("[^\n]+") do last = line end
  return last
end

-- fetch runs usage.sh --refresh and writes the result to the log. The script
-- prints one line on success, and the reason for a failure on stderr.
local function fetch()
  local start = os.time()
  local result, err = rex.exec({ script, "--refresh" }, { timeout = TIMEOUT })
  local secs = os.time() - start
  if not result then
    log("fetch failed: cannot run " .. script .. ": " .. tostring(err))
  elseif result.timed_out then
    log(("fetch failed: no answer in %ds"):format(TIMEOUT))
  elseif not result.ok then
    log(("fetch failed in %ds (exit %d): %s"):format(secs, result.code, last_line(result.stderr)))
  else
    log(("fetch ok in %ds: %s"):format(secs, last_line(result.stdout)))
  end
end

local paused = false

local function tick()
  local list = clients()
  if not list then
    log("stopped: the server does not answer")
    rex.stop(0)
  end
  if app_shows_session(list) then
    if paused then
      log("resumed: a Rex app shows a session")
      paused = false
    end
    fetch()
  elseif not paused then
    log("paused: no Rex app shows a session")
    paused = true
  end
end

local list = clients()
if not list or has_label(list) then rex.stop(0) end
rex.call("client.set_label", { label = LABEL })
log(("started: a fetch each %ds while a Rex app shows a session"):format(INTERVAL))
tick()
rex.every(INTERVAL, tick)
