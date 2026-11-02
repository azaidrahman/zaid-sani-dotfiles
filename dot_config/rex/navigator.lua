-- Move between panes with ctrl+h/j/k/l. This is the Rex copy of the
-- vim-tmux-navigator tmux plugin.
--
-- This file defines four actions: navigate_left, navigate_down, navigate_up
-- and navigate_right. If the foreground program of the pane is in PROGRAMS,
-- the action sends the key to that program. Then nvim goes to its window on
-- that side. At the edge of nvim, nvim runs `rex focus`
-- (~/.config/nvim/lua/zaid/core/navigator.lua). tmux is in the list, so that
-- tmux in a Rex pane still gets the keys. For all other programs, the action
-- focuses the pane on that side.
--
-- The keys are bound to actions, not to functions, so that the Command
-- Palette shows them (custom.lua). An action cannot send its key on to the
-- terminal, as a function binding can. Thus the action sends the key itself.

local PROGRAMS = { nvim = true, vim = true, view = true, fzf = true, tmux = true }

local DIRECTIONS = {
  { direction = "left", letter = "h", title = "Left" },
  { direction = "down", letter = "j", title = "Down" },
  { direction = "up", letter = "k", title = "Up" },
  { direction = "right", letter = "l", title = "Right" },
}

-- send_ctrl sends ctrl+LETTER to the block. The event goes straight to the
-- block, so the key bindings do not see it again.
local function send_ctrl(ctx, letter)
  local _, err = rex.call("block.event", {
    session_id = ctx.session_id,
    block_id = ctx.block_id,
    event = {
      type = "key",
      payload = {
        key = "key_" .. letter,
        mods = "ctrl",
        consumed_mods = "",
        text = "",
        unshifted_codepoint = string.byte(letter),
        composing = false,
        action = "press",
      },
    },
  })
  if err ~= nil then error(err, 0) end
end

for _, d in ipairs(DIRECTIONS) do
  rex.action{
    name = "navigate_" .. d.direction,
    title = "Move Focus " .. d.title,
    description = "Go to the nvim window on the " .. d.direction
      .. ". At the edge of nvim, or in another program, focus the pane on the "
      .. d.direction .. ".",
    keywords = "navigate focus pane window split nvim vim tmux " .. d.direction,
    -- Hold the key to move again, for example down the list of fzf.
    repeats = true,
    run = function(ctx)
      local process = rex.block.call("com.superlogical.terminal", "process",
        { block_id = ctx.block_id }) or {}
      if PROGRAMS[(process.foreground or {}).name] then
        send_ctrl(ctx, d.letter)
        return
      end
      rex.session.focus_direction{ session_id = ctx.session_id, direction = d.direction }
    end,
  }
end
