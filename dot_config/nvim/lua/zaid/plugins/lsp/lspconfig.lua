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

		-- local on_attach_pyright = function(client, _)
		-- 	-- Disable all capabilities except hoverProvider
		-- 	client.server_capabilities.completionProvider = false
		-- 	client.server_capabilities.definitionProvider = false
		-- 	client.server_capabilities.typeDefinitionProvider = false
		-- 	client.server_capabilities.implementationProvider = false
		-- 	client.server_capabilities.referencesProvider = false
		-- 	client.server_capabilities.documentSymbolProvider = false
		-- 	client.server_capabilities.workspaceSymbolProvider = false
		-- 	client.server_capabilities.codeActionProvider = false
		-- 	client.server_capabilities.documentFormattingProvider = false
		-- 	client.server_capabilities.documentRangeFormattingProvider = false
		-- 	client.server_capabilities.renameProvider = false
		-- 	client.server_capabilities.signatureHelpProvider = false
		-- 	client.server_capabilities.documentHighlightProvider = false
		-- 	client.server_capabilities.foldingRangeProvider = false
		-- 	client.server_capabilities.semanticTokensProvider = false
		-- 	client.server_capabilities.declarationProvider = false
		-- 	client.server_capabilities.callHierarchyProvider = false
		-- 	client.server_capabilities.diagnosticProvider = false
		--
		-- 	-- Enable hoverProvider
		-- 	client.server_capabilities.hoverProvider = true
		-- end

		local on_attach_ruff = function(client, _)
			if client.name == "ruff" then
				-- disable hover in favor of pyright
				client.server_capabilities.hoverProvider = false
				-- Create a keymap for manual linting (if desired)
				-- vim.keymap.set(
				-- 	"n",
				-- 	"<leader>ml",
				-- 	vim.lsp.buf.lint,
				-- 	{ buffer = bufnr, desc = "Lint current file with Ruff" }
				-- )
			end
		end
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
                "yamlls",
				"emmet_language_server",
				"marksman",
				"basedpyright",
				"ruff",
				"terraformls",
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

				-- terraformls = {
				-- 	filetypes = { "terraform","hcl", "terraform-vars"},
				-- },
				-- pyright = {
				-- 	on_attach = on_attach_pyright,
				-- 	capabilities = (function()
				-- 		local capabilities = vim.lsp.protocol.make_client_capabilities()
				-- 		capabilities.textDocument.publishDiagnostics.tagSupport.valueSet = { 2 }
				-- 		return capabilities
				-- 	end)(),
				-- 	settings = {
				-- 		python = {
				-- 			analysis = {
				-- 				useLibraryCodeForTypes = true,
				-- 				diagnosticSeverityOverrides = {
				-- 					reportUnusedVariable = "warning",
				-- 				},
				-- 				typeCheckingMode = "off", -- Set type-checking mode to off
				-- 				diagnosticMode = "off", -- Disable diagnostics entirely
				-- 			},
				-- 		},
				-- 	},
				-- },

				ruff = {
					on_attach = on_attach_ruff,
					init_options = {
						settings = {
							lint = {
								args = { "--select=E,F,I" },
							},
						},
					},
				},

				tailwindcss = {
					-- Add any specific tailwindcss configuration here if needed
				},

                -- Added from this github: https://github.com/Allaman/nvimhttps://github.com/Allaman/nvim
				yamlls = {
					capabilities = {
						textDocument = {
							foldingRange = {
								dynamicRegistration = false,
								lineFoldingOnly = true,
							},
						},
					},
					settings = {
						redhat = { telemetry = { enabled = false } },
						yaml = {
							schemaStore = {
								enable = true,
								url = "https://www.schemastore.org/api/json/catalog.json",
							},
							format = { enabled = false },
							-- enabling this conflicts between Kubernetes resources, kustomization.yaml, and Helmreleases
							validate = false,
							schemas = {
								kubernetes = "*.yaml",
								["http://json.schemastore.org/github-workflow"] = ".github/workflows/*",
								["http://json.schemastore.org/github-action"] = ".github/action.{yml,yaml}",
								["https://raw.githubusercontent.com/microsoft/azure-pipelines-vscode/master/service-schema.json"] = "azure-pipelines*.{yml,yaml}",
								["https://raw.githubusercontent.com/ansible/ansible-lint/main/src/ansiblelint/schemas/ansible.json#/$defs/tasks"] = "roles/tasks/*.{yml,yaml}",
								["https://raw.githubusercontent.com/ansible/ansible-lint/main/src/ansiblelint/schemas/ansible.json#/$defs/playbook"] = "*play*.{yml,yaml}",
								["http://json.schemastore.org/prettierrc"] = ".prettierrc.{yml,yaml}",
								["http://json.schemastore.org/kustomization"] = "kustomization.{yml,yaml}",
								["http://json.schemastore.org/chart"] = "Chart.{yml,yaml}",
								["https://json.schemastore.org/dependabot-v2"] = ".github/dependabot.{yml,yaml}",
								["https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/assets/javascripts/editor/schema/ci.json"] = "*gitlab-ci*.{yml,yaml}",
								["https://raw.githubusercontent.com/OAI/OpenAPI-Specification/main/schemas/v3.1/schema.json"] = "*api*.{yml,yaml}",
								["https://raw.githubusercontent.com/compose-spec/compose-spec/master/schema/compose-spec.json"] = "*docker-compose*.{yml,yaml}",
								["https://raw.githubusercontent.com/argoproj/argo-workflows/master/api/jsonschema/schema.json"] = "*flow*.{yml,yaml}",
							},
						},
					},
				},

				-- Add other server configurations as needed
			},
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

		-- for _, server_name in ipairs(lsp_servers.enabled) do
		-- 	local opts = lsp_servers.configs[server_name] or {}
		-- 	require("lspconfig")[server_name].setup(opts)
		-- end
	end,
}
