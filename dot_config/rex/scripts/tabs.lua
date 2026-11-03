-- Read the tabs of a Rex server. list-tabs.lua and host-tabs-watcher.lua
-- load this file with dofile.
--
-- collect() returns the ID of the host and one record for each tab of each
-- session. It reads the server that the `rex do` script connects to. Add
-- `-S HOST` to `rex do` to read a host.
--
-- A script must attach to a session before it can read the session. A
-- script that runs with `rex do --all` attaches to all sessions after its
-- top level ends. Another script gives attach = true. collect then attaches
-- with session.attach_all, which also lists the sessions.
--
-- Over a relay of the tailnet, each call can take 30 ms. Thus collect makes
-- few calls: one view for each session, and three calls for each tab.
--
-- The title, the processes, and the status of a tab come from the focused
-- block of the tab. `bid` is the ID of that block. The Rex app records the
-- status of each block that you saw. The Alfred workflow finds the tabs
-- with a status that you did not see, with `bid`.
--
-- rex.json encodes an empty table as an empty object, not as an empty list.
-- Thus `tabs` or `status.records` can be {} in the JSON.

local TERMINAL = "com.superlogical.terminal"

local M = {}

function M.collect(opts)
  opts = opts or {}
  local status = rex.call("server.status", {}) or {}
  local list, err
  if opts.attach then
    list, err = rex.call("session.attach_all", { event_scope = "session" })
  else
    list, err = rex.call("session.list", {})
  end
  if not list then return nil, err end

  local tabs = {}
  for _, s in ipairs(list.sessions or {}) do
    local sid = s.session_id
    -- A session can close while collect runs. Then view gives nil.
    local view = rex.session.view{ session_id = sid } or {}
    for pos, w in ipairs(view.windows or {}) do
      local panes = 0
      for _, layer in ipairs(w.layers or {}) do
        panes = panes + #(layer.blocks or {})
      end
      -- If a block method fails, the record holds an empty table.
      local function call(method)
        return rex.block.call(TERMINAL, method,
          { session_id = sid, block_id = w.focused_block_id }) or {}
      end
      tabs[#tabs + 1] = {
        sid = sid, slabel = s.label or "", pos = pos,
        wid = w.window_id, wlabel = w.label or "", panes = panes,
        bid = w.focused_block_id or "",
        title = call("title"), proc = call("process"),
        status = call("program_status"),
      }
    end
  end
  return { host_id = status.host_id or "", tabs = tabs }
end

-- save writes value as JSON to path. A reader never sees half a file,
-- because save writes a temporary file and then renames it.
function M.save(path, value)
  local text, err = rex.json.encode(value)
  if not text then return nil, err end
  local tmp = path .. ".tmp"
  local f, ferr = io.open(tmp, "w")
  if not f then return nil, ferr end
  f:write(text, "\n")
  f:close()
  return os.rename(tmp, path)
end

return M
