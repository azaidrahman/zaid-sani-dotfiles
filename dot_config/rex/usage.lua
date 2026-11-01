-- The status center. This is the Rex copy of tmux prefix+u.
--
-- The status_center action opens a float in the center of the window. The
-- float runs scripts/usage.sh, which draws the same view as
-- ~/.tmux/scripts/claude-usage.sh: the gcloud and kube context, and the usage
-- of the AI subscription that the focused pane runs. Any key closes the float.
--
-- To run the action without the key, use `rex do status_center`.
--
-- A poller (scripts/usage-poller.lua) fetches the Claude usage each minute
-- while a Rex app shows a session. Thus the float draws the usage at once.

local TERMINAL = "com.superlogical.terminal"
local CONFIG_HOME = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
local SCRIPT = CONFIG_HOME .. "/rex/scripts/usage.sh"
local POLLER = CONFIG_HOME .. "/rex/scripts/usage-poller.lua"

-- The size that the script gives includes the border of a tmux popup: 2
-- columns and 2 rows. The frame of a Rex float takes 2 columns and 4 rows.
local EXTRA_ROWS = 2

-- If the script cannot give a size, use this size in cells.
local FALLBACK_SIZE = { 82, 20 }

-- The float must not fill more than this fraction of the window.
local MAX_FRACTION = 0.95

-- rect_of returns the {x, y, w, h} fractions of block_id in a layout tree.
local function rect_of(node, block_id)
  if type(node) ~= "table" then return nil end
  if node.block_id == block_id and node.rect then return node.rect end
  for _, child in pairs(node) do
    local rect = rect_of(child, block_id)
    if rect then return rect end
  end
  return nil
end

-- place returns the window that holds block_id, and the fractions of the
-- window that the block fills. A zoomed block fills the whole window.
local function place(view, block_id)
  for _, window in ipairs(view.windows or {}) do
    local rect = rect_of(window.layers, block_id)
    if rect then
      if window.zoomed_block_id == block_id then rect = { 0, 0, 1, 1 } end
      return window, rect
    end
  end
  return nil, { 0, 0, 1, 1 }
end

-- focused_block returns the focused block of the active window.
local function focused_block(view)
  for _, window in ipairs(view.windows or {}) do
    if window.window_id == view.active_window_id then
      return window.focused_block_id
    end
  end
  return nil
end

-- wanted_size returns the size in cells that the view needs. The script
-- reads the size from its cache. This call runs in the environment of the
-- Rex server, where PATH has only the system directories.
local function wanted_size(pid)
  local result = rex.exec({ SCRIPT, "--size", pid }, { timeout = 5 })
  if result and result.ok then
    local w, h = result.stdout:match("(%d+)x(%d+)")
    if w then return tonumber(w), tonumber(h) end
  end
  return FALLBACK_SIZE[1], FALLBACK_SIZE[2]
end

local function open(ctx)
  local view = assert(rex.session.view{ session_id = ctx.session_id })
  local block_id = ctx.block_id or focused_block(view)
  if not block_id then return nil end

  -- The first process of the terminal. The script finds the agent under it.
  local process = rex.block.call(TERMINAL, "process", { block_id = block_id }) or {}
  local pid = tostring((process.child or {}).pid or "")
  local cwd = (process.foreground or {}).cwd

  local want_w, want_h = wanted_size(pid)
  want_h = want_h + EXTRA_ROWS

  -- A float is sized in fractions of the window. The size of the window in
  -- cells is the size of the block divided by the fraction that it fills.
  local window, rect = place(view, block_id)
  local size = rex.block.call(TERMINAL, "size", { block_id = block_id }) or {}
  local win_w = (size.columns or 160) / rect[3]
  local win_h = (size.rows or 48) / rect[4]
  local fw = math.min(want_w / win_w, MAX_FRACTION)
  local fh = math.min(want_h / win_h, MAX_FRACTION)

  return rex.session.new_layer{
    session_id = ctx.session_id,
    window_id = window and window.window_id or nil,
    bounds = { (1 - fw) / 2, (1 - fh) / 2, fw, fh },
    focus = true,
    layout = rex.layout.block{
      flavor = "com.superlogical.terminal.shell",
      label = "Status",
      options = {
        -- Do not set shell = "none". The login shell gives the PATH that
        -- finds claude, codex and jq.
        command = { SCRIPT, pid, cwd or "" },
        cwd = cwd,
      },
    },
  }
end

-- start_poller starts the poller each time the server loads this file. If a
-- poller runs already, the new one exits.
--
-- The poller needs the rex binary of the server. A command that this file
-- runs is a child of the process that loads the file, so the parent of the
-- command is the server. `rex config check` loads the file in the CLI, and
-- the parent of the command is not a server. Thus a check starts no poller.
local function start_poller()
  local ps = rex.exec({ "/bin/sh", "-c", 'ps -o args= -p "$PPID"' }, { timeout = 5 })
  local rex_bin = ps and ps.ok and ps.stdout:match("^(.-/rex) server run")
  if not rex_bin then return end
  rex.exec.start(
    { rex_bin, "--autostart=false", "do", POLLER, "script=" .. SCRIPT },
    { detach = true, stdout = false, stderr = false })
end

start_poller()

rex.action{
  name = "status_center",
  title = "Show Usage and Status",
  description = "Show the gcloud and kube context, and the usage of the AI subscription that the focused pane runs.",
  keywords = "claude codex litellm usage quota gcloud kube",
  run = function(ctx) return open(ctx) end,
}
