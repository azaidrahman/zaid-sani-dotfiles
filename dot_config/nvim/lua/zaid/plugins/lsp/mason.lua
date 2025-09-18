return {
	"williamboman/mason.nvim",
	lazy = false,
	opts = {
		ui = {
			border = "rounded",
		},
	},
	dependencies = {
		"williamboman/mason-lspconfig.nvim",
		"WhoIsSethDaniel/mason-tool-installer.nvim",
	},
	config = function()
		-- import mason and mason_lspconfig
		local mason = require("mason")
		local mason_tool_installer = require("mason-tool-installer")


		-- enable mason and configure icons
		mason.setup({
			ui = {
				icons = {
					package_installed = "✓",
					package_pending = "➜",
					package_uninstalled = "✗",
				},
			},
		})

		mason_tool_installer.setup({
			ensure_installed = {
				"prettier", -- prettier formatter
				"stylua", -- lua formatter
				"isort", -- python formatter
				"pylint",
				"clangd",
			},

		})
	end,
}
