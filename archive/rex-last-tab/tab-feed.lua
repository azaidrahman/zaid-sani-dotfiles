-- The feed of the tabs of one server. last-tab-watcher.lua starts one copy
-- for each server, with `rex [-S HOST] do --all`. Thus the calls and the
-- events of this script go to that server.
--
-- The feed writes one JSON object on each line of stdout:
--   {"type":"session","session_id":S,"active":W,"windows":[W,...]}
--       the tabs of a session and its active tab. The feed writes one for
--       each session when it starts, and again when a tab opens or closes.
--   {"type":"active","session_id":S,"window_id":W}
--       a different tab of the session became active.
--   {"type":"gone","session_id":S}
--       the session closed.
--   {"type":"ready"}
--       the feed sent all sessions that were open when it started.
--
-- If the process parent=PID stops, the feed stops with status 0. Thus a feed
-- does not stay after last-tab-watcher.lua stops.

local PARENT = rex.args.parent and tostring(rex.args.parent)

local function emit(t)
  local text = rex.json.encode(t)
  if not text then return end
  io.stdout:write(text, "\n")
  io.stdout:flush()
end

local function send_session(sid)
  local v = rex.session.view{ session_id = sid }
  if not v then return end
  local windows = {}
  for _, w in ipairs(v.windows or {}) do windows[#windows + 1] = w.window_id end
  emit({ type = "session", session_id = sid, active = v.active_window_id, windows = windows })
end

rex.on("active_window_changed", function(ctx, ev)
  local sid = ctx.session_id or ev.session_id
  if sid and ev.window_id then
    emit({ type = "active", session_id = sid, window_id = ev.window_id })
  end
end)

for _, name in ipairs({ "window_created", "window_closed" }) do
  rex.on(name, function(ctx, ev)
    local sid = ctx.session_id or ev.session_id
    if sid then send_session(sid) end
  end)
end

rex.on("session_destroyed", function(ctx, ev)
  local sid = ev.session_id or ctx.session_id
  if sid then emit({ type = "gone", session_id = sid }) end
end)

rex.every(5, function()
  if not PARENT then return end
  local r = rex.exec({ "/bin/kill", "-0", PARENT })
  if not (r and r.ok) then rex.stop(0) end
end)

-- The calls of a `--all` script work only after its top level ends.
rex.after(0, function()
  local list = rex.call("session.list")
  for _, s in ipairs(list and list.sessions or {}) do send_session(s.session_id) end
  emit({ type = "ready" })
end)
