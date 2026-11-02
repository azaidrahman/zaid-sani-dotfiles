-- Move between panes with ctrl+h/j/k/l. This is the Rex copy of the
-- vim-tmux-navigator tmux plugin.
--
-- navigate(direction) returns a function for rex.bind. If the foreground
-- program of the pane is in PROGRAMS, the function sends the key to that
-- program. Then nvim goes to its window on that side. At the edge of nvim,
-- nvim runs `rex focus` (~/.config/nvim/lua/zaid/core/navigator.lua). tmux is
-- in the list, so that tmux in a Rex pane still gets the keys. For all other
-- programs, the function focuses the pane on that side.

local PROGRAMS = { nvim = true, vim = true, view = true, fzf = true, tmux = true }

return function(direction)
  return function(ctx)
    local process = rex.block.call("com.superlogical.terminal", "process",
      { block_id = ctx.block_id }) or {}
    if PROGRAMS[(process.foreground or {}).name] then
      return false -- A function binding that returns false sends the key on.
    end
    rex.session.focus_direction{ session_id = ctx.session_id, direction = direction }
    return true
  end
end
