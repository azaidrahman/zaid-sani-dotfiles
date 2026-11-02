-- Hold a session. This is the Rex copy of tmux prefix+b
-- (~/.tmux/scripts/toggle-hold.sh).
--
-- A held session is work that waits. Its label starts with "[HOLD] ", and it
-- moves to the end of the session list, so the sidebar shows it below the
-- active sessions. The tab picker (tab_picker.lua) shows the tabs of a held
-- session in a group of their own. When you release a session, it moves to
-- the end of the active sessions, just before the first held session.
--
-- The hold list is the source of truth, not the label. An agent can rename a
-- session, and the new label has no marker. scripts/hold-watcher.lua sees
-- the rename and puts the marker back. The list holds one session id on each
-- line, in $REX_HOLD_DIR/held. The default directory is
-- ~/.local/state/rex-hold.
--
-- To run the action without the key, use `rex do toggle_hold`.

local PREFIX = "[HOLD] "
local MAX_LABEL = 128 -- the longest label that session.set_label accepts

local HOME = os.getenv("HOME")
local STATE = os.getenv("REX_HOLD_DIR")
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-hold")
local LIST = STATE .. "/held"

local CONFIG_HOME = os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")
local WATCHER = CONFIG_HOME .. "/rex/scripts/hold-watcher.lua"

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

-- write_list writes a new file and moves it into place, so that the watcher
-- never reads half a list.
local function write_list(ids)
  rex.exec({ "mkdir", "-p", STATE })
  local tmp = LIST .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then error("toggle_hold: cannot write " .. tmp, 0) end
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

local function has_marker(label)
  return label:sub(1, #PREFIX) == PREFIX
end

local function toggle(ctx)
  local sid = ctx.session_id
  if not sid then error("toggle_hold: no session", 0) end
  local list, err = rex.call("session.list")
  if not list then error("toggle_hold: " .. tostring(err), 0) end

  local sessions = list.sessions or {}
  local session
  for _, s in ipairs(sessions) do
    if s.session_id == sid then session = s end
  end
  if not session then error("toggle_hold: no session " .. sid, 0) end

  local ids = read_list()
  local function held(s)
    return contains(ids, s.session_id) or has_marker(s.label or "")
  end
  local label = session.label or ""
  if has_marker(label) then label = label:sub(#PREFIX + 1) end

  if held(session) then
    -- Change the list before the label. Otherwise the watcher sees a held
    -- session without its marker, and puts the marker back.
    local rest = {}
    for _, id in ipairs(ids) do
      if id ~= sid then rest[#rest + 1] = id end
    end
    write_list(rest)
    rex.session.set_label{ session_id = sid, label = label }
    local before
    for _, s in ipairs(sessions) do
      if s.session_id ~= sid and held(s) then
        before = s.session_id
        break
      end
    end
    -- Without before_session_id, the session moves to the end.
    rex.call("session.move", { session_id = sid, before_session_id = before })
    return { session_id = sid, held = false, label = label }
  end

  ids[#ids + 1] = sid
  write_list(ids)
  label = PREFIX .. label:sub(1, MAX_LABEL - #PREFIX)
  rex.session.set_label{ session_id = sid, label = label }
  rex.call("session.move", { session_id = sid })
  return { session_id = sid, held = true, label = label }
end

rex.action{
  name = "toggle_hold",
  title = "Hold or Release Session",
  description = "Mark the session as held and move it to the end of the list, or release it.",
  keywords = "hold park pause release session marker",
  run = function(ctx) return toggle(ctx) end,
}

-- Start the watcher each time the server loads this file. If a watcher runs
-- already, the new one exits.
require("background").start({ "--all", WATCHER, "state=" .. STATE })
