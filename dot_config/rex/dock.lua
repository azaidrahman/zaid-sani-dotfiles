-- Dock a float. A float is a pane in a floating layer of a tab, such as the
-- float of prefix+y (commit_draft.lua).
--
-- The dock_float action moves the focused float into the tiled layout of its
-- tab. The float becomes a regular pane on the right of an anchor pane. The
-- program in the pane keeps running. The empty floating layer goes away.
--
-- The anchor is the pane that opened the float, if the code that opened it
-- called remember. Otherwise the anchor is the largest tiled pane of the tab.
--
-- To run the action without the key, use `rex do dock_float`.

local M = {}

-- origin maps the block of a float to the block that opened it.
local origin = {}

-- remember records that opener_block opened the float float_block.
function M.remember(float_block, opener_block)
  if float_block and opener_block then origin[float_block] = opener_block end
end

-- leaves adds the block_id -> rect of each block in a layout tree to out.
local function leaves(node, out)
  if type(node) ~= "table" then return out end
  if node.block_id and node.rect then out[node.block_id] = node.rect end
  if node.split then
    leaves(node.split.before, out)
    leaves(node.split.after, out)
  end
  return out
end

local function area(rect) return rect[3] * rect[4] end

-- largest returns the block of blocks (block_id -> rect) with the largest area.
local function largest(blocks)
  local best
  for id, rect in pairs(blocks) do
    if not best or area(rect) > area(blocks[best]) then best = id end
  end
  return best
end

local function dock(ctx)
  local view = assert(rex.session.view{ session_id = ctx.session_id })
  local block_id = ctx.block_id
  if not block_id then
    for _, window in ipairs(view.windows or {}) do
      if window.window_id == view.active_window_id then
        block_id = window.focused_block_id
      end
    end
  end
  if not block_id then error("dock_float: no pane has focus", 0) end

  for _, window in ipairs(view.windows or {}) do
    local tiled, floating = {}, false
    for _, layer in ipairs(window.layers or {}) do
      local blocks = leaves(layer.layout, {})
      if layer.kind == "tiled" then
        tiled = blocks
      elseif blocks[block_id] then
        floating = true
      end
    end
    if floating then
      local anchor = origin[block_id]
      if not (anchor and tiled[anchor]) then anchor = largest(tiled) end
      if not anchor then error("dock_float: the tab has no tiled pane", 0) end
      local moved, err = rex.session.move_block{
        session_id = ctx.session_id,
        block_id = block_id,
        anchor_block_id = anchor,
        direction = "horizontal",
        side = "after",
      }
      if not moved then error("dock_float: " .. tostring(err), 0) end
      rex.session.focus_block{ session_id = ctx.session_id, block_id = block_id }
      origin[block_id] = nil
      return { block_id = block_id, anchor_block_id = anchor }
    end
  end
  error("dock_float: the pane is not a float", 0)
end

rex.action{
  name = "dock_float",
  title = "Dock Float as Pane",
  description = "Move the focused float into the tiled layout, as a regular pane beside the pane that opened it.",
  keywords = "float floating layer dock tile embed pane popup",
  run = function(ctx) return dock(ctx) end,
}

return M
