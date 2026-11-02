-- ctrl+h/j/k/l move between nvim windows and the panes around nvim.
--
-- In tmux, the plugin does the work. In Rex, nvim moves between its own
-- windows. At the edge, nvim runs `rex focus` to focus the Rex pane on that
-- side. The Rex half is in ~/.config/rex/init.lua.
local function navigate(wincmd, tmux_cmd, rex_direction)
	return function()
		if vim.env.TMUX then
			vim.cmd(tmux_cmd)
			return
		end
		local win = vim.api.nvim_get_current_win()
		vim.cmd("wincmd " .. wincmd)
		if win == vim.api.nvim_get_current_win() and vim.env.REX_SESSION then
			vim.system({ "rex", "focus", "-s", vim.env.REX_SESSION, rex_direction })
		end
	end
end

return {
	"christoomey/vim-tmux-navigator",
	enabled = true,
	cmd = {
		"TmuxNavigateLeft",
		"TmuxNavigateDown",
		"TmuxNavigateUp",
		"TmuxNavigateRight",
		"TmuxNavigatePrevious",
		"TmuxNavigatorProcessList",
	},
	keys = {
		{ "<c-h>", navigate("h", "TmuxNavigateLeft", "left") },
		{ "<c-j>", navigate("j", "TmuxNavigateDown", "down") },
		{ "<c-k>", navigate("k", "TmuxNavigateUp", "up") },
		{ "<c-l>", navigate("l", "TmuxNavigateRight", "right") },
		{ "<c-\\>", "<cmd><C-U>TmuxNavigatePrevious<cr>" },
	},
}
