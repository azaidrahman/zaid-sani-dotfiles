-- Copy text from a pane with vim keys. This is the Rex copy of tmux copy mode.
--
-- The copy_mode action opens a float over the focused pane. The float runs
-- scripts/copy-mode.sh. The script reads the text of the pane into a
-- read-only nvim buffer. Press v or V to select text, then y to copy it and
-- quit. Press q to quit without a copy. See scripts/copy-mode-nvim.lua.
--
-- To run the action without the key, use `rex do copy_mode`.

local SHELL = "com.superlogical.terminal.shell"

local dock = require("dock")

-- The float can run on a host that did not load this file. The home
-- directory is not the same on each Mac. Thus a shell finds the script on the
-- host that runs the float. See diff_review.lua. A test sets REX_COPY_MODE
-- to a stub script.
local GATE = 'exec "${REX_COPY_MODE:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/scripts/copy-mode.sh}" "$@"'

-- The float fills this fraction of the window, as in diff_review.lua.
local WIDTH, HEIGHT = 0.98, 0.96

local function open(ctx)
  local view = assert(rex.session.view{ session_id = ctx.session_id })
  local block_id = ctx.block_id
  if not block_id then
    for _, window in ipairs(view.windows or {}) do
      if window.window_id == view.active_window_id then
        block_id = window.focused_block_id
      end
    end
  end
  if not block_id then error("copy mode: no pane has focus", 0) end

  local result = assert(rex.session.new_layer{
    session_id = ctx.session_id,
    window_id = view.active_window_id,
    bounds = { (1 - WIDTH) / 2, (1 - HEIGHT) / 2, WIDTH, HEIGHT },
    focus = true,
    layout = rex.layout.block{
      flavor = SHELL,
      label = "copy",
      options = {
        command = { "sh", "-c", GATE, "copy-mode.sh", ctx.session_id or "", block_id },
      },
    },
  })
  dock.remember((result.block_ids or {})[1], block_id)
  return result
end

rex.action{
  name = "copy_mode",
  title = "Copy Mode",
  description = "Copy text from the focused pane. Move with vim keys, select with v, then press y to copy.",
  keywords = "copy mode scrollback select yank vim",
  run = function(ctx) return open(ctx) end,
}
