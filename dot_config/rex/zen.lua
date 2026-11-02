-- Zen mode. This is the Rex copy of tmux prefix+z
-- (~/.tmux/scripts/tmux-zen.sh), in the style of zen-mode.nvim.
--
-- The zen action does these steps in the tab of the pane:
--   1. It splits a placeholder pane off the pane. The placeholder keeps the
--      place of the pane in the layout.
--   2. It covers the tab with a dark backdrop float.
--   3. It floats the pane in the middle of the tab, in front of the backdrop.
--      The program in the pane keeps running.
--   4. It changes the text size of the pane.
-- Run the action again in the pane to leave zen mode. The pane goes back into
-- the place of the placeholder, so the layout comes back exactly. Then the
-- placeholder and the backdrop close.
--
-- Do not move the pane to another tab. The Rex app does not draw a pane that
-- moves from another tab into a float: the server has the pane in the float,
-- but the app shows only the backdrop. Floating a pane in its own tab is the
-- same step as the "Float Pane" action of the app, and docking it back is the
-- same step as dock_float (dock.lua).
--
-- tmux needed a temporary session, a saved layout string, and many steps to
-- put the pane back in its old place. The placeholder does that work here.
--
-- The text size is a setting of each pane. Rex cannot set a size directly.
-- Thus the zen size is the default size plus FONT_STEPS steps of "Increase
-- Font Size", or minus the steps if FONT_STEPS is negative (init.lua has the
-- same note for font_zoom_out). When you leave zen mode, the pane goes back to
-- the default size. A size that you set by hand is lost.
--
-- Zen mode does not hide the sidebar. Press cmd+e to hide it. The app
-- resizes the panes only after the sidebar stops its slide. With the slide,
-- zen mode took about 850 ms to start. Without it, zen mode takes about
-- 250 ms. Also, the app does not tell Lua if the sidebar is visible, so a
-- toggle could show a sidebar that you had hidden.
--
-- The state file records each pane in zen mode, with its placeholder and its
-- backdrop. The file is $REX_ZEN_DIR/zen.json. The default directory is
-- ~/.local/state/rex-zen. The file survives `rex config reload`.
--
-- To run the action without the key, use `rex do zen`. The width argument
-- sets the width of the float, as a fraction of the tab, such as
-- `rex do zen width=0.6`.

local TERMINAL = "com.superlogical.terminal"
local SHELL = "com.superlogical.terminal.shell"

local DEFAULT_WIDTH = 0.75 -- the width of the float, as in tmux @zen-width
local MIN_WIDTH, MAX_WIDTH = 0.2, 0.95
-- The default size is 20 points and font_zoom_out is 12 points. Zen mode is
-- in the middle, at 16 points.
local FONT_STEPS = -4
local BACKDROP = "#000d14" -- one step darker than the nvim background

-- The backdrop and the placeholder run a shell that hides the cursor and
-- waits. Without a program that waits, the pane closes. The backdrop covers
-- the placeholder, so the text of the placeholder shows only if the backdrop
-- closes.
local BACKDROP_SCRIPT = [[printf '\033[?25l'; exec tail -f /dev/null]]
local PLACEHOLDER_SCRIPT = [[printf '\033[?25l\n\033[2m  This pane holds the place of a pane in zen mode.\033[0m\n'; exec tail -f /dev/null]]

local HOME = os.getenv("HOME")
local STATE = os.getenv("REX_ZEN_DIR")
  or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-zen")
local FILE = STATE .. "/zen.json"

-- --- state ----------------------------------------------------------------

-- Each entry has session_id, block_id (the pane), placeholder_id,
-- backdrop_id, and backdrop_layer_id.
local function read_state()
  local f = io.open(FILE, "r")
  if not f then return {} end
  local text = f:read("*a")
  f:close()
  local entries = rex.json.decode(text)
  if type(entries) ~= "table" then return {} end
  return entries
end

-- write_state writes a new file and moves it into place, so that a reader
-- never sees half a file.
local function write_state(entries)
  local tmp = FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    -- Make the directory only the first time. rex.exec starts a process.
    rex.exec({ "mkdir", "-p", STATE })
    f = io.open(tmp, "w")
  end
  if not f then error("zen: cannot write " .. tmp, 0) end
  -- An empty table encodes as {}. Write [] so that the file is always a list.
  f:write(#entries > 0 and rex.json.encode(entries) or "[]")
  f:close()
  os.rename(tmp, FILE)
end

-- --- the view -------------------------------------------------------------

-- locate returns the window and the layer that hold a block, or nil.
local function locate(view, block_id)
  for _, window in ipairs(view.windows or {}) do
    for _, layer in ipairs(window.layers or {}) do
      for _, block in ipairs(layer.blocks or {}) do
        if block.block_id == block_id then return window, layer end
      end
    end
  end
end

local function focused_block(view)
  for _, window in ipairs(view.windows or {}) do
    if window.window_id == view.active_window_id then return window.focused_block_id end
  end
end

-- largest_tiled returns the block with the largest area in the tiled layer of
-- a window. dock.lua uses the same rule.
local function largest_tiled(window)
  local best, best_area
  local function walk(node)
    if type(node) ~= "table" then return end
    if node.block_id and node.rect then
      local area = node.rect[3] * node.rect[4]
      if not best or area > best_area then best, best_area = node.block_id, area end
    end
    if node.split then
      walk(node.split.before)
      walk(node.split.after)
    end
  end
  for _, layer in ipairs(window.layers or {}) do
    if layer.kind == "tiled" then walk(layer.layout) end
  end
  return best
end

-- --- the app --------------------------------------------------------------

-- Only an app has a text size. `rex do zen` runs as the CLI, and a test has
-- no app. Then zen mode changes only the layout.
local function from_app(ctx)
  if not ctx.client_id then return false end
  local r = rex.call("client.inspect", { client_id = ctx.client_id })
  local info = r and r.client and r.client.info
  return info ~= nil and info.kind == "app"
end

-- The app runs queued actions after the action returns, in order, on the pane
-- that has focus then. Each path below focuses the pane before it returns.
local function queue_enter()
  rex.client.queue("client.font.reset")
  local step = FONT_STEPS > 0 and "client.font.increase" or "client.font.decrease"
  for _ = 1, math.abs(FONT_STEPS) do rex.client.queue(step) end
end

local function queue_exit()
  rex.client.queue("client.font.reset")
end

-- --- enter and leave ------------------------------------------------------

local function waiting_pane(label, script)
  return rex.layout.block{
    flavor = SHELL,
    label = label,
    options = { command = { "/bin/sh", "-c", script }, shell = "none" },
  }
end

local function width_of(args)
  local w = tonumber((args or {}).width)
  if not w or w < MIN_WIDTH or w > MAX_WIDTH then return DEFAULT_WIDTH end
  return w
end

local function close_block(ctx, block_id)
  if block_id then rex.call("block.close", { session_id = ctx.session_id, block_id = block_id }) end
end

local function close_layer(ctx, layer_id)
  if layer_id then rex.session.close_layer{ session_id = ctx.session_id, layer_id = layer_id } end
end

local function enter(ctx, view, block_id, args)
  local window, layer = locate(view, block_id)
  if not window then error("zen: no pane " .. block_id, 0) end
  if layer.kind ~= "tiled" then error("zen: the pane is a float; dock it first", 0) end

  -- The new split takes the place of the pane. When the pane floats, the split
  -- goes away and the placeholder has the place of the pane.
  local split, err = rex.session.new_split{
    session_id = ctx.session_id,
    anchor_id = block_id,
    direction = "horizontal",
    side = "after",
    focus = false,
    layout = waiting_pane("zen placeholder", PLACEHOLDER_SCRIPT),
  }
  if not split then error("zen: " .. tostring(err), 0) end
  local placeholder = (split.block_ids or {})[1]

  -- The newest float is in front. Make the backdrop first.
  local backdrop, berr = rex.session.new_layer{
    session_id = ctx.session_id,
    window_id = window.window_id,
    bounds = { 0, 0, 1, 1 },
    focus = false,
    layout = waiting_pane("zen backdrop", BACKDROP_SCRIPT),
  }
  if not backdrop then
    close_block(ctx, placeholder)
    error("zen: " .. tostring(berr), 0)
  end
  local backdrop_id = (backdrop.block_ids or {})[1]
  if backdrop_id then
    rex.block.call(TERMINAL, "set_theme", {
      session_id = ctx.session_id,
      block_id = backdrop_id,
      args = { background = BACKDROP, scheme = "dark" },
    })
  end

  local w = width_of(args)
  local floated, ferr = rex.session.float_block{
    session_id = ctx.session_id,
    block_id = block_id,
    bounds = { (1 - w) / 2, 0, w, 1 },
  }
  if not floated then
    close_layer(ctx, backdrop.layer_id)
    close_block(ctx, placeholder)
    error("zen: " .. tostring(ferr), 0)
  end
  rex.session.focus_block{ session_id = ctx.session_id, block_id = block_id }

  local entries = read_state()
  entries[#entries + 1] = {
    session_id = ctx.session_id,
    block_id = block_id,
    placeholder_id = placeholder,
    backdrop_id = backdrop_id,
    backdrop_layer_id = backdrop.layer_id,
  }
  write_state(entries)
  if from_app(ctx) then queue_enter() end
  return { zen = true, block_id = block_id, placeholder_id = placeholder, layer_id = floated.layer_id }
end

-- dock moves the pane back into the tiled layout of its tab. If the
-- placeholder is still there, the pane takes its place. If not, the pane goes
-- beside the largest pane of the tab, as dock_float does. A stranded pane is
-- better than a lost one.
local function dock(ctx, view, entry)
  local anchor, where = entry.placeholder_id, "placeholder"
  if not locate(view, anchor) then
    local window = locate(view, entry.block_id)
    anchor, where = window and largest_tiled(window), "beside"
  end
  if not anchor then return "float" end
  local moved, err = rex.session.move_block{
    session_id = ctx.session_id,
    block_id = entry.block_id,
    anchor_block_id = anchor,
    direction = "horizontal",
    side = "after",
  }
  if not moved then error("zen: " .. tostring(err), 0) end
  if where == "placeholder" then close_block(ctx, anchor) end
  return where
end

local function leave(ctx, view, entry)
  local where = dock(ctx, view, entry)
  close_layer(ctx, entry.backdrop_layer_id)
  rex.session.focus_block{ session_id = ctx.session_id, block_id = entry.block_id }
  if from_app(ctx) then queue_exit() end
  return { zen = false, block_id = entry.block_id, restored = where }
end

-- --- the action -----------------------------------------------------------

-- prune drops the entries of this session whose pane is gone, and closes the
-- placeholder and the backdrop of each one. Close nothing else: the state file
-- is the proof that zen mode made them. The second result is a set of the
-- blocks that prune closed.
local function prune(ctx, view, entries)
  local keep, closed = {}, {}
  for _, e in ipairs(entries) do
    if e.session_id == ctx.session_id and not locate(view, e.block_id) then
      if locate(view, e.placeholder_id) then
        close_block(ctx, e.placeholder_id)
        closed[e.placeholder_id] = true
      end
      if locate(view, e.backdrop_id) then
        close_layer(ctx, e.backdrop_layer_id)
        closed[e.backdrop_id] = true
      end
    else
      keep[#keep + 1] = e
    end
  end
  return keep, closed
end

-- match returns the entry for a block: the pane itself, its placeholder, or
-- its backdrop.
local function match(entries, session_id, block_id)
  for i, e in ipairs(entries) do
    if e.session_id == session_id and (e.block_id == block_id
      or e.placeholder_id == block_id or e.backdrop_id == block_id) then
      return i, e
    end
  end
end

-- leave_or returns the result of leaving zen mode if the block is a pane in
-- zen mode, its placeholder, or its backdrop. If the pane closed, leave_or
-- closes the placeholder and the backdrop. If the block was one of them, there
-- is nothing more to do. Otherwise leave_or calls otherwise(view, block_id).
local function leave_or(ctx, name, otherwise)
  if not ctx.session_id then error(name .. ": no session", 0) end
  local view = assert(rex.session.view{ session_id = ctx.session_id })
  local block_id = ctx.block_id or focused_block(view)
  if not block_id then error(name .. ": no pane has focus", 0) end

  local saved = read_state()
  local entries, closed = prune(ctx, view, saved)
  local i, entry = match(entries, ctx.session_id, block_id)
  if entry then table.remove(entries, i) end
  -- cmd+w runs this on each close. Write the file only if it changed.
  if #entries ~= #saved then write_state(entries) end
  if entry then return leave(ctx, view, entry) end
  if closed[block_id] then return { zen = false, cleaned = true } end
  return otherwise(view, block_id)
end

rex.action{
  name = "zen",
  title = "Zen Mode",
  description = "Float the pane in the middle of its tab over a dark backdrop, with a smaller text size, or put it back.",
  keywords = "zen focus center centre distraction free writing",
  args = { width = "number?" },
  run = function(ctx, args)
    return leave_or(ctx, "zen", function(view, block_id) return enter(ctx, view, block_id, args) end)
  end,
}

-- cmd+w is File > Close in the app (client.close). In zen mode, cmd+w leaves
-- zen mode instead. Then the pane goes back to its place, and nothing closes
-- by mistake.
rex.action{
  name = "close_or_leave_zen",
  title = "Close or Leave Zen Mode",
  description = "Do File > Close. In zen mode, leave zen mode and put the pane back instead.",
  keywords = "close pane zen leave",
  run = function(ctx)
    return leave_or(ctx, "close_or_leave_zen", function() rex.client.queue("client.close") end)
  end,
}
