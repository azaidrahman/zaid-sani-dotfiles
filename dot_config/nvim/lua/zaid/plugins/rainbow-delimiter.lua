-- https://github.com/HiPhish/rainbow-delimiters.nvim/blob/master/doc/rainbow-delimiters.txt
return {
	"HiPhish/rainbow-delimiters.nvim",
	enabled = true,
	event = { "BufReadPost", "BufNewFile" },
	config = function()
		-- either set the global and let the plugin pick it up:
		---@type rainbow_delimiters.config
		vim.g.rainbow_delimiters = {
			strategy = {
				[""] = "rainbow-delimiters.strategy.global",
				vim = "rainbow-delimiters.strategy.local",
			},
			query = {
				[""] = "rainbow-delimiters",
				lua = "rainbow-blocks",
			},
			priority = {
				[""] = 110,
				lua = 210,
			},
			highlight = {
				"RainbowDelimiterRed",
				"RainbowDelimiterYellow",
				"RainbowDelimiterBlue",
				"RainbowDelimiterOrange",
				"RainbowDelimiterGreen",
				"RainbowDelimiterViolet",
				"RainbowDelimiterCyan",
			},
		}

		-- or call the setup function directly:
		require("rainbow-delimiters.setup").setup(vim.g.rainbow_delimiters)
	end,
}
