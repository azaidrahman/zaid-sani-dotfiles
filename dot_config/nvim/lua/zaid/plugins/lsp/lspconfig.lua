return {
	"neovim/nvim-lspconfig",
	event = { "BufReadPre", "BufNewFile" },
	dependencies = {
		-- Core LSP dependencies
		"hrsh7th/cmp-nvim-lsp",
		{ "antosha417/nvim-lsp-file-operations", config = true },
		-- Mason LSP dependencies
		"williamboman/mason.nvim",
		"williamboman/mason-lspconfig.nvim",
	},
	config = function()
		-- Set up diagnostic signs
		local signs = {
			[vim.diagnostic.severity.ERROR] = " ",
			[vim.diagnostic.severity.WARN] = " ",
			[vim.diagnostic.severity.HINT] = "󰠠 ",
			[vim.diagnostic.severity.INFO] = " ",
		}

		vim.diagnostic.config({
			signs = {
				text = signs,
			},
			virtual_text = false,
			underline = true,
			update_in_insert = false,
		})

		-- NOTE: LSP Keybinds
		vim.api.nvim_create_autocmd("LspAttach", {
			desc = "LSP actions",
			group = vim.api.nvim_create_augroup("UserLspConfig", {}),
			callback = function(ev)
                -- Search  *grr* *gra* *grn* *gri* *grt* *i_CTRL-S* in help for other default keybinds
				-- Buffer local mappings
				local opts = { buffer = ev.buf, silent = true }

				opts.desc = "Smart rename"
				vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)

				opts.desc = "Show buffer diagnostics"
				vim.keymap.set("n", "<leader>D", "<cmd>Telescope diagnostics bufnr=0<CR>", opts)

				opts.desc = "Show line diagnostics"
				vim.keymap.set("n", "<leader>d", vim.diagnostic.open_float, opts)
				opts.desc = "Go to declaration"
				vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)

				opts.desc = "Show LSP definitions"
				vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)

				opts.desc = "Restart LSP"
				vim.keymap.set("n", "<leader>rs", ":LspRestart<CR>", opts)
			end,
		})

		-- NOTE: ENABLE/DISABLE HERE - Define LSP configurations in a single table
		local lsp_servers = {
			-- List of servers to enable
			enabled = {
				"lua_ls",
				"ts_ls",
				"html",
				"cssls",
                "gopls",
				-- "emmet_ls",
				"emmet_language_server",
				"marksman",
				-- Add "tailwindcss" here if you want to enable it
				-- Add "pyright" here if you want to enable it
			},

			-- Configuration for each server
			configs = {
				lua_ls = {
					settings = {
						Lua = {
							diagnostics = {
								globals = { "vim" },
							},
							completion = {
								callSnippet = "Replace",
							},
							workspace = {
								library = {
									[vim.fn.expand("$VIMRUNTIME/lua")] = true,
									[vim.fn.stdpath("config") .. "/lua"] = true,
								},
							},
						},
					},
				},

				emmet_ls = {
					filetypes = {
						"vue",
						"html",
						"typescriptreact",
						"javascriptreact",
						"css",
						"sass",
						"scss",
						"less",
						"svelte",
					},
				},

				emmet_language_server = {
					filetypes = {
						"css",
						"eruby",
						"html",
						"javascript",
						"javascriptreact",
						"less",
						"sass",
						"vue",
						"scss",
						"pug",
						"typescriptreact",
					},
					init_options = {
						includeLanguages = {},
						excludeLanguages = {},
						extensionsPath = {},
						preferences = {},
						showAbbreviationSuggestions = true,
						showExpandedAbbreviation = "always",
						showSuggestionsAsSnippets = false,
						syntaxProfiles = {},
						variables = {},
					},
				},

				ts_ls = {
					filetypes = { "typescript", "javascript", "javascriptreact", "typescriptreact", "vue" },
					init_options = {
						plugins = {
							{
								name = "@vue/typescript-plugin",
								location = vim.env.HOME
									.. "/.local/share/nvim/lazy/vue-language-server/node_modules/@vue/language-server",
								languages = { "vue" },
							},
						},
					},
				},

				pyright = {
					cmd = { "pyright", "--stdio" },
					settings = {
						python = {
							venvPath = ".",
							venv = ".venv",
							pythonPath = vim.fn.exepath("python3"),
						},
					},
				},

				tailwindcss = {
					-- Add any specific tailwindcss configuration here if needed
				},

				-- Add other server configurations as needed
			}
		}

		-- Configure and enable each LSP server
		for _, server_name in ipairs(lsp_servers.enabled) do
			-- Check if we have custom configuration for this server
			if lsp_servers.configs[server_name] then
				vim.lsp.config(server_name, lsp_servers.configs[server_name])
			else
				-- Use default configuration if no custom one is provided
				vim.lsp.config(server_name, {})
			end
		end

		-- Enable all configured servers
		vim.lsp.enable(lsp_servers.enabled)

		-- Setup mason-lspconfig to use the new API
		require("mason-lspconfig").setup({
			ensure_installed = lsp_servers.enabled,
			handlers = {
				function(server_name)
					-- Enable servers that aren't in our explicit configuration
					if not vim.tbl_contains(lsp_servers.enabled, server_name) then
						vim.lsp.enable(server_name)
					end
				end,
			},
		})
	end,
}
