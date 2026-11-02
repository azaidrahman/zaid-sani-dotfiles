-- The watcher of the tabs on one host. remote-tabs-watcher.lua starts one
-- copy for each host, with `rex -S HOST do --all`. Thus the calls and the
-- events of this script go to the host, not to the server of this Mac.
--
-- The watcher writes the tabs of the host to the file out=PATH. The file has
-- the format of list-tabs.lua (see tabs.lua), plus the label of the host in
-- `server` and the time of the write in `time`. The Alfred workflow Rex Tabs
-- reads the file, so it does not wait for the host.
--
-- The watcher writes the file again after each change on the host, and each
-- HEARTBEAT seconds. A burst of events gives one write. Claude changes its
-- status often while it works, so the watcher writes at most one time in
-- each MIN_GAP seconds.
--
-- If the host does not answer, the watcher stops with status 1. If the
-- process parent=PID stops, the watcher stops with status 0. Thus a watcher
-- does not stay after remote-tabs-watcher.lua stops.
--
-- Arguments: out=PATH, server=LABEL, parent=PID, heartbeat=SECONDS.

local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)") or "./"
local tabs = dofile(dir .. "tabs.lua")

local LABEL = "host-tabs-watcher"
local OUT = rex.args.out
local SERVER = rex.args.server or ""
local PARENT = rex.args.parent and tostring(rex.args.parent)
local HEARTBEAT = tonumber(rex.args.heartbeat) or 30
local DEBOUNCE = 0.3 -- seconds from the first event of a burst to a write
local MIN_GAP = 2    -- seconds from one write to the next

if not OUT then
  io.stderr:write("Error: give the file of the copy as out=PATH\n")
  rex.stop(2)
end

local function write()
  local result, err = tabs.collect()
  if not result then
    io.stderr:write("Error: ", tostring(err), "\n")
    rex.stop(1)
    return
  end
  result.server = SERVER
  result.time = os.time()
  local ok, serr = tabs.save(OUT, result)
  if not ok then
    io.stderr:write("Error: ", tostring(serr), "\n")
    rex.stop(1)
  end
end

-- schedule writes the file after a short wait. Events that arrive during
-- the wait or during the gap after a write give one more write.
local busy, dirty = false, false
local function schedule()
  if busy then
    dirty = true
    return
  end
  busy = true
  rex.after(DEBOUNCE, function()
    write()
    rex.after(MIN_GAP, function()
      busy = false
      if dirty then
        dirty = false
        schedule()
      end
    end)
  end)
end

-- These events change what the file holds.
for _, name in ipairs({
  "session_created", "session_destroyed", "session_label_changed",
  "session_view_changed", "window_label_changed",
  "terminal.title_changed", "terminal.pwd_changed", "terminal.process_changed",
  "terminal.program_status_changed", "terminal.program_status_removed",
}) do
  rex.on(name, schedule)
end

local function parent_alive()
  if not PARENT then return true end
  local r = rex.exec({ "/bin/kill", "-0", PARENT })
  return r and r.ok
end

-- The heartbeat keeps `time` new, so Alfred knows that the copy is current.
rex.every(HEARTBEAT, function()
  if not parent_alive() then
    rex.stop(0)
    return
  end
  write()
end)

rex.call("client.set_label", { label = LABEL })
-- The calls of a `--all` script work only after its top level ends.
rex.after(0, write)
