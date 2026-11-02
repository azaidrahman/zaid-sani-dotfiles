-- The data of the tab picker. tab-picker.sh runs this script with `rex do`
-- and reads the JSON that it returns. One script makes all the API calls,
-- because tv reads the list again each second.
--
-- The result is { tabs = { tab, ... } }, in the order of the sessions and of
-- their tabs. A tab has these fields:
--   session_id, session    the session and its label
--   held                   true if the session is on hold (hold.lua)
--   window_id, key, label  the tab, the last 8 characters of its id, its label
--   block_id               the pane for the preview
--   state, msg             the most urgent program status of the panes
--   agents                 the number of panes that run an agent
--   claude_id, claude_cwd  the Claude session in the pane, if there is one
--
-- Arguments: hold_list= the path of the hold list, claude_sessions= the
-- directory where Claude writes <pid>.json.

local HOME = os.getenv("HOME")
local HOLD_LIST = rex.args.hold_list
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-hold/held")
local CLAUDE_SESSIONS = rex.args.claude_sessions or (HOME .. "/.claude/sessions")
local TERMINAL = "com.superlogical.terminal"
local PREFIX = "[HOLD] "
-- A higher number is more urgent. The most urgent pane speaks for the tab.
local RANK = { blocked = 4, error = 3, working = 2, done = 1, idle = 1 }

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local held = {}
for id in (read_file(HOLD_LIST) or ""):gmatch("[^\n]+") do held[id] = true end

-- claude_of returns the Claude session of a terminal, or nil. Claude can be
-- the foreground process, or the parent of a tool that Claude runs.
local function claude_of(process)
  local chain = { process.foreground }
  for _, p in ipairs(process.ancestors or {}) do chain[#chain + 1] = p end
  for _, p in ipairs(chain) do
    if p and p.name == "claude" and p.pid then
      local text = read_file(CLAUDE_SESSIONS .. "/" .. p.pid .. ".json")
      local ok, info = pcall(rex.json.decode, text or "")
      if ok and type(info) == "table" and info.sessionId then return info end
    end
  end
  return nil
end

local function pane_of(sid, block_id)
  local args = { session_id = sid, block_id = block_id }
  local best
  local status = rex.block.call(TERMINAL, "program_status", args) or {}
  for _, r in ipairs(status.records or {}) do
    if not best or (RANK[r.state] or 0) > (RANK[best.state] or 0) then best = r end
  end
  local claude = claude_of(rex.block.call(TERMINAL, "process", args) or {})
  return {
    block_id = block_id,
    state = best and best.state,
    msg = best and best.msg,
    rank = best and (RANK[best.state] or 0) or 0,
    claude_id = claude and claude.sessionId,
    claude_cwd = claude and claude.cwd,
  }
end

-- Rex names a new tab "Window <id>". For such a tab, the picker shows the
-- title of the pane instead, as Claude sets it.
local function name_of(sid, window, pane)
  local label = window.label or ""
  if not label:match("^Window %x%x%x%x%x%x%x%x$") then return label end
  local t = rex.block.call(TERMINAL, "title", { session_id = sid, block_id = pane.block_id })
  local title = t and t.title or ""
  if title == "" then return label end
  return title
end

local tabs = {}
local list = rex.call("session.list") or {}
for _, s in ipairs(list.sessions or {}) do
  local sid = s.session_id
  local label = s.label or ""
  -- A script can read a session only after it attaches to it. The attach
  -- also returns the view.
  local attached = rex.call("session.attach", { session_id = sid })
  local view = attached and attached.view
  for _, w in ipairs(view and view.windows or {}) do
    local win, agents = nil, 0
    for _, layer in ipairs(w.layers or {}) do
      -- Floats, such as this picker, are not part of the tab.
      if layer.kind == "tiled" then
        for _, b in ipairs(layer.blocks or {}) do
          if b.creator_name == TERMINAL then
            local p = pane_of(sid, b.block_id)
            if p.claude_id or p.state then agents = agents + 1 end
            -- The focused pane wins a tie.
            if not win or p.rank > win.rank
              or (p.rank == win.rank and b.block_id == w.focused_block_id) then
              win = p
            end
          end
        end
      end
    end
    if win then
      tabs[#tabs + 1] = {
        session_id = sid,
        session = label,
        held = held[sid] == true or label:sub(1, #PREFIX) == PREFIX,
        window_id = w.window_id,
        key = w.window_id:sub(-8),
        label = name_of(sid, w, win),
        block_id = win.block_id,
        state = win.state,
        msg = win.msg,
        agents = agents,
        claude_id = win.claude_id,
        claude_cwd = win.claude_cwd,
      }
    end
  end
end

return { tabs = tabs }
