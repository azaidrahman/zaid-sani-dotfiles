-- Formatting via conform.nvim
-- Runs formatters on demand (<leader>mp) or can be enabled for format-on-save

return {
	"stevearc/conform.nvim",
	event = { "BufReadPre", "BufNewFile" },
	config = function()
		local conform = require("conform")

		-- Custom formatter overrides
		conform.formatters.prettier = {
			args = {
				"--stdin-filepath",
				"$FILENAME",
				"--tab-width",
				"4",
				"--use-tabs",
				"false",
				"--single-attribute-per-line",
			},
		}
		conform.formatters.prettier_yaml = {
			command = "prettier",
			stdin = true,
			args = {
				"--stdin-filepath",
				"$FILENAME",
				"--tab-width",
				"2",
				"--use-tabs",
				"false",
			},
		}
		conform.formatters.shfmt = {
			prepend_args = { "-i", "4" },
		}

		conform.setup({
			formatters_by_ft = {
				-- Web
				css = { "prettier" },
				html = { "prettier" },
				json = { "prettier" },
				graphql = { "prettier" },
				liquid = { "prettier" },

				-- Go: goimports organizes imports, gofumpt enforces strict formatting
				go = { "goimports", "gofumpt" },

				-- Python: organize imports then format
				python = { "ruff_organize_imports", "ruff_format" },

				-- Terraform/HCL
				terraform = { "terraform_fmt" },
				["terraform-vars"] = { "terraform_fmt" },
				hcl = { "packer_fmt" },

				-- Shell
				sh = { "shfmt" },
				zsh = { "beautysh" },

				-- Data / Docs
				yaml = { "prettier_yaml" },
				markdown = { "prettier" },
				["markdown.mdx"] = { "prettier", "markdownlint-cli2", "markdown-toc" },
				lua = { "stylua" },
			},
			notify_on_error = true,
			format_on_save = function(bufnr)
				if vim.bo[bufnr].filetype == "yaml" then
					return
				end

				return {
					lsp_fallback = true,
					async = false,
					timeout_ms = 1000,
				}
			end,
		})

		vim.keymap.set({ "n", "v" }, "<leader>mp", function()
			conform.format({
				lsp_fallback = true,
				async = false,
				timeout_ms = 1000,
			})
		end, { desc = "Format file or range" })
	end,
}
