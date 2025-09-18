return {
	"stevearc/conform.nvim",
	event = { "BufReadPre", "BufNewFile" },
	dependencies = { "mason.nvim" }, -- Ensure Mason is loaded first
	config = function()
		local conform = require("conform")

		-- Define formatters configuration in a structured table
		local formatters_config = {
			prettier = {
				args = {
					"--stdin-filepath",
					"$FILENAME",
					"--tab-width",
					"4",
					"--use-tabs",
					"false",
					"--single-attribute-per-line",
				},
			},
			shfmt = {
				prepend_args = { "-i", "4" },
			},
			["markdown-toc"] = {
				condition = function(_, ctx)
					for _, line in ipairs(vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false)) do
						if line:find("<!%-%- toc %-%->") then
							return true
						end
					end
				end,
			},
			-- ["markdownlint-cli2"] = {
			-- 	condition = function(_, ctx)
			-- 		local diag = vim.tbl_filter(function(d)
			-- 			return d.source == "markdownlint"
			-- 		end, vim.diagnostic.get(ctx.buf))
			-- 		return #diag > 0
			-- 	end,
			-- },
		}

		-- Define formatters by filetype
		local formatters_by_ft = {
			javascript = { "prettier" },
			typescript = { "prettier" },
			javascriptreact = { "prettier" },
			typescriptreact = { "prettier" },
			svelte = { "prettier" },
			css = { "prettier" },
			html = { "prettier" },
			json = { "prettier" },
			yaml = { "prettier" },
			graphql = { "prettier" },
			liquid = { "prettier" },
			vue = { "prettier" },
			lua = { "stylua" },
			python = { "black" },
			zsh = { "beautysh" },
			markdown = { "prettier" },
			["markdown.mdx"] = { "prettier", "markdownlint-cli2", "markdown-toc" },
			sh = { "shfmt" },
		}

		-- Configure individual formatters
		for formatter_name, config in pairs(formatters_config) do
			conform.formatters[formatter_name] = config
		end

		-- Setup conform with our configuration
		conform.setup({
			formatters_by_ft = formatters_by_ft,

			-- Enable format on save with LSP fallback
			-- You can uncomment this if you want automatic formatting
			-- format_on_save = {
			--   timeout_ms = 1000,
			--   lsp_fallback = true,
			-- },

			-- Set up notifies for formatting status
			notify_on_error = true,
		})

		-- Create keymaps for formatting
		vim.keymap.set({ "n", "v" }, "<leader>mp", function()
			conform.format({
				lsp_fallback = true,
				async = false,
				timeout_ms = 1000,
			})
		end, { desc = "Format file or range with formatters" })

		-- Add a keymap to toggle format on save
		vim.g.format_on_save_enabled = false
	end,
}
