-- ctrl+h/j/k/l go to the nvim window on that side. At the edge of nvim, they go
-- to the pane on that side in tmux or in Rex. ctrl+\ goes back to the last
-- window or pane. The keys are in keymaps.lua.
--
-- The terminal sends these keys to nvim, and nvim decides where to go. The
-- other half is in the terminal: the vim-tmux-navigator tmux plugin
-- (~/.tmux/conf.d/plugins.conf), or ~/.config/rex/navigator.lua.
--
-- This module replaces the vim-tmux-navigator nvim plugin
-- (plugins_archive/vim-tmux-navigator.lua). That plugin added its own
-- mappings when it loaded, and its mappings did not know about Rex.
local env = require("zaid.core.env")

local M = {}

-- The flag for tmux select-pane and the direction for rex focus.
local SIDES = {
	h = { tmux = "-L", rex = "left" },
	j = { tmux = "-D", rex = "down" },
	k = { tmux = "-U", rex = "up" },
	l = { tmux = "-R", rex = "right" },
	p = { tmux = "-l" }, -- Rex has no last pane.
}

-- True when the last move went from nvim to a pane. Then ctrl+\ goes back to
-- that pane, not to the last nvim window.
local in_pane = false

-- Focus the pane on a side. Return false if there is no pane to focus.
local function focus_pane(side)
	local cmd
	if env.in_tmux then
		cmd = { "tmux", "select-pane", "-t", vim.env.TMUX_PANE, SIDES[side].tmux }
	elseif env.in_rex and SIDES[side].rex then
		cmd = { "rex", "focus", "-s", vim.env.REX_SESSION, SIDES[side].rex }
	end
	if cmd then
		vim.system(cmd)
	end
	return cmd ~= nil
end

-- Go to the window on a side: "h", "j", "k", "l", or "p" for the last window.
-- At the edge of nvim, go to the pane on that side.
function M.move(side)
	if side == "p" and in_pane and focus_pane(side) then
		return
	end
	local win = vim.api.nvim_get_current_win()
	vim.cmd.wincmd(side)
	in_pane = win == vim.api.nvim_get_current_win() and focus_pane(side)
end

return M
