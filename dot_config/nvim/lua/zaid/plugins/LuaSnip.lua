return {
	"L3MON4D3/LuaSnip",
	version = "v2.*",
	build = "make install_jsregexp",
	dependencies = {
		"rafamadriz/friendly-snippets", -- Collection of VSCode-style snippets
	},
	config = function()
		local luasnip = require("luasnip")

		-- Load VSCode-style snippets from friendly-snippets
		require("luasnip.loaders.from_vscode").lazy_load()

		-- Load custom snippets from zaid/snippets/ folder
		local custom_snippets = {
			-- Add languages here as { filetype = "filename_without_extension" }
			{ filetype = "vue", file = "vue" },
			-- Example: { filetype = "lua", file = "lua" },
			-- { filetype = "python", file = "python" },
		}

		for _, snippet_info in ipairs(custom_snippets) do
            local path = "zaid.plugins.snippets." .. snippet_info.file
			local ok, snippets = pcall(require, path)
			if ok and type(snippets) == "table" then
				luasnip.add_snippets(snippet_info.filetype, snippets)
			else
				print("Warning: Failed to load snippets for " .. snippet_info.filetype)
			end
		end
	end,
}
