return {
	"hrsh7th/nvim-cmp",
	event = "InsertEnter",
	branch = "main", -- Fix for deprecated functions in Neovim 0.13+
	dependencies = {
		"hrsh7th/cmp-buffer", -- Source for text in buffer
		"hrsh7th/cmp-path", -- Source for file system paths
		"saadparwaiz1/cmp_luasnip", -- LuaSnip integration
		"onsails/lspkind.nvim", -- VSCode-style pictograms
		"roobert/tailwindcss-colorizer-cmp.nvim",
		"supermaven-inc/supermaven-nvim", -- supermaven
	},
	config = function()
		local cmp = require("cmp")
		local lspkind = require("lspkind")
		local colorizer = require("tailwindcss-colorizer-cmp").formatter
		local luasnip = require("luasnip")

		-- Helper to replace termcodes
		local rhs = function(keys)
			return vim.api.nvim_replace_termcodes(keys, true, true, true)
		end

		-- LSP kind icons
		local lsp_kinds = {
			Class = " ",
			Color = " ",
			Constant = " ",
			Constructor = " ",
			Enum = " ",
			EnumMember = " ",
			Event = " ",
			Field = " ",
			File = " ",
			Folder = " ",
			Function = " ",
			Interface = " ",
			Keyword = " ",
			Method = " ",
			Module = " ",
			Operator = " ",
			Property = " ",
			Reference = " ",
			Snippet = " ",
			Struct = " ",
			Text = " ",
			TypeParameter = " ",
			Unit = " ",
			Value = " ",
			Variable = " ",
		}

		-- Returns current column
		local column = function()
			local _, col = unpack(vim.api.nvim_win_get_cursor(0))
			return col
		end

		-- Check if inside a snippet
		local in_snippet = function()
			local session = require("luasnip.session")
			local node = session.current_nodes[vim.api.nvim_get_current_buf()]
			if not node then
				return false
			end
			local snippet = node.parent.snippet
			local snip_begin_pos, snip_end_pos = snippet.mark:pos_begin_end()
			local pos = vim.api.nvim_win_get_cursor(0)
			return pos[1] - 1 >= snip_begin_pos[1] and pos[1] - 1 <= snip_end_pos[1]
		end

		-- Check if in whitespace
		local in_whitespace = function()
			local col = column()
			return col == 0 or vim.api.nvim_get_current_line():sub(col, col):match("%s")
		end

		-- Check if in leading indent
		local in_leading_indent = function()
			local col = column()
			local line = vim.api.nvim_get_current_line()
			local prefix = line:sub(1, col)
			return prefix:find("^%s*$")
		end

		-- Get shift width
		local shift_width = function()
			if vim.o.softtabstop <= 0 then
				return vim.fn.shiftwidth()
			else
				return vim.o.softtabstop
			end
		end

		-- Smart backspace (handles dedent if requested)
		local smart_bs = function(dedent)
			local keys
			if vim.o.expandtab then
				keys = dedent and rhs("<C-D>") or rhs("<BS>")
			else
				local col = column()
				local line = vim.api.nvim_get_current_line()
				local prefix = line:sub(1, col)
				if in_leading_indent() then
					keys = rhs("<BS>")
				else
					local previous_char = prefix:sub(#prefix, #prefix)
					if previous_char ~= " " then
						keys = rhs("<BS>")
					else
						keys = rhs("<C-\\><C-o>:set expandtab<CR><BS><C-\\><C-o>:set noexpandtab<CR>")
					end
				end
			end
			vim.api.nvim_feedkeys(keys, "nt", true)
		end

		-- Smart tab (handles indent/expansion)
		local smart_tab = function()
			local keys
			if vim.o.expandtab then
				keys = "<Tab>" -- Insert spaces
			else
				local col = column()
				local line = vim.api.nvim_get_current_line()
				local prefix = line:sub(1, col)
				if prefix:find("^%s*$") then
					keys = "<Tab>" -- Insert hard tab in leading indent
				else
					local sw = shift_width()
					local previous_char = prefix:sub(#prefix, #previous_char)
					local previous_column = #prefix - #previous_char + 1
					local current_column = vim.fn.virtcol({ vim.fn.line("."), previous_column }) + 1
					local remainder = (current_column - 1) % sw
					local move = remainder == 0 and sw or sw - remainder
					keys = (" "):rep(move)
				end
			end
			vim.api.nvim_feedkeys(rhs(keys), "nt", true)
		end

		-- Select next item or fallback
		local select_next_item = function(fallback)
			if cmp.visible() then
				cmp.select_next_item()
			else
				fallback()
			end
		end

		-- Select previous item or fallback
		local select_prev_item = function(fallback)
			if cmp.visible() then
				cmp.select_prev_item()
			else
				fallback()
			end
		end

		-- Custom confirm (handles Insert/Replace behavior)
		local confirm = function(entry)
			local behavior = cmp.ConfirmBehavior.Replace
			if entry then
				local completion_item = entry.completion_item
				local newText = ""
				if completion_item.textEdit then
					newText = completion_item.textEdit.newText
				elseif type(completion_item.insertText) == "string" and completion_item.insertText ~= "" then
					newText = completion_item.insertText
				else
					newText = completion_item.word or completion_item.label or ""
				end

				local diff_after = math.max(0, entry.replace_range["end"].character + 1) - entry.context.cursor.col
				if entry.context.cursor_after_line:sub(1, diff_after) ~= newText:sub(-diff_after) then
					behavior = cmp.ConfirmBehavior.Insert
				end
			end
			cmp.confirm({ select = true, behavior = behavior })
		end

		cmp.setup({
			experimental = {
				ghost_text = false, -- Toggled dynamically below
			},
			completion = {
				completeopt = "menu,menuone,noinsert",
			},
			window = {
				documentation = {
					border = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
				},
				completion = {
					border = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
				},
			},
			snippet = {
				expand = function(args)
					luasnip.lsp_expand(args.body)
				end,
			},
            -- NOTE: CHANGE HERE IF YOU WANT TO ADD MORE SOURCES
			sources = cmp.config.sources({
				{ name = "luasnip" }, -- Snippets
				{ name = "supermaven" }, -- Uncomment if using Supermaven
				{ name = "nvim_lsp" },
				{ name = "buffer" },
				{ name = "path" },
			}),
			mapping = cmp.mapping.preset.insert({
				["<C-Space>"] = cmp.mapping.complete(),
				["<C-e>"] = cmp.mapping.abort(),
				["<C-d>"] = cmp.mapping(function()
					cmp.close_docs()
				end, { "i", "s" }),

				-- Your requested keybinds (menu navigation and confirm)
				["<C-n>"] = cmp.mapping(function(fallback)
					if cmp.visible() then
						cmp.select_next_item() -- Go down in menu
					elseif luasnip.expand_or_jumpable() then
						luasnip.expand_or_jump() -- Fallback to snippet expand/jump forward
					else
						fallback()
					end
				end, { "i", "s" }),

				["<C-p>"] = cmp.mapping(function(fallback)
					if cmp.visible() then
						cmp.select_prev_item() -- Go up in menu
					elseif luasnip.jumpable(-1) then
						luasnip.jump(-1) -- Fallback to snippet jump backward
					else
						fallback()
					end
				end, { "i", "s" }),

				["<C-y>"] = cmp.mapping(function(fallback)
					if cmp.visible() then
						local entry = cmp.get_selected_entry()
						confirm(entry) -- Confirm selection
					elseif luasnip.expandable() then
						luasnip.expand() -- Expand snippet if at trigger
					else
						fallback()
					end
				end, { "i", "s" }),

				-- NEW: Snippet jumping (C-j forward, C-k backward) -- avoids tmux conflicts
				["<C-j>"] = cmp.mapping(function(fallback)
					if luasnip.jumpable(1) then
						luasnip.jump(1) -- Jump forward in snippet slots
					elseif cmp.visible_docs() then
						cmp.scroll_docs(4) -- Fallback to scroll docs forward
					else
						fallback()
					end
				end, { "i", "s" }),

				["<C-k>"] = cmp.mapping(function(fallback)
					if luasnip.jumpable(-1) then
						luasnip.jump(-1) -- Jump backward in snippet slots
					elseif cmp.visible_docs() then
						cmp.scroll_docs(-4) -- Fallback to scroll docs backward
					else
						fallback()
					end
				end, { "i", "s" }),

				-- Retained your smart Tab/S-Tab (enhanced for standard super-tab jumping)
				["<Tab>"] = cmp.mapping(function(fallback)
					if cmp.visible() then
						local entries = cmp.get_entries()
						if #entries == 1 then
							confirm(entries[1])
						else
							cmp.select_next_item()
						end
					elseif luasnip.expand_or_locally_jumpable() then
						luasnip.expand_or_jump() -- Standard: Expand or jump forward
					elseif in_whitespace() then
						smart_tab()
					else
						cmp.complete()
					end
				end, { "i", "s" }),

				["<S-Tab>"] = cmp.mapping(function(fallback)
					if cmp.visible() then
						cmp.select_prev_item()
					elseif in_snippet() and luasnip.jumpable(-1) then
						luasnip.jump(-1) -- Standard: Jump backward
					elseif in_leading_indent() then
						smart_bs(true) -- Dedent
					elseif in_whitespace() then
						smart_bs()
					else
						fallback()
					end
				end, { "i", "s" }),
			}),
			formatting = {
				format = function(entry, vim_item)
					-- Custom LSP kind icons
					vim_item.kind = string.format("%s %s", lsp_kinds[vim_item.kind] or "", vim_item.kind)

					-- Menu tags (e.g., [Buffer], [LuaSnip])
					vim_item.menu = ({
						buffer = "[Buffer]",
						nvim_lsp = "[LSP]",
						luasnip = "[LuaSnip]",
						nvim_lua = "[Lua]",
						latex_symbols = "[LaTeX]",
					})[entry.source.name]

					-- Apply lspkind formatting
					vim_item = lspkind.cmp_format({
						maxwidth = 25,
						ellipsis_char = "...",
					})(entry, vim_item)

					-- Apply Tailwind colorizer if from LSP
					if entry.source.name == "nvim_lsp" then
						vim_item = colorizer(entry, vim_item)
					end

					return vim_item
				end,
			},
		})

		-- Global keymaps for snippet jumping (works even outside cmp menu)
		vim.keymap.set({ "i", "s" }, "<C-j>", function()
			if luasnip.jumpable(1) then
				luasnip.jump(1)
			end
		end, { silent = true, desc = "Jump forward to next snippet slot" })

		vim.keymap.set({ "i", "s" }, "<C-k>", function()
			if luasnip.jumpable(-1) then
				luasnip.jump(-1)
			end
		end, { silent = true, desc = "Jump backward to previous snippet slot" })

		-- Ghost text toggling (only at word boundaries)
		local config = require("cmp.config")
		local toggle_ghost_text = function()
			if vim.api.nvim_get_mode().mode ~= "i" then
				return
			end

			local cursor_column = vim.fn.col(".")
			local current_line_contents = vim.fn.getline(".")
			local character_after_cursor = current_line_contents:sub(cursor_column, cursor_column)

			local should_enable_ghost_text = character_after_cursor == ""
				or vim.fn.match(character_after_cursor, [[\k]]) == -1

			local current = config.get().experimental.ghost_text
			if current ~= should_enable_ghost_text then
				config.set_global({
					experimental = {
						ghost_text = should_enable_ghost_text,
					},
				})
			end
		end

		vim.api.nvim_create_autocmd({ "InsertEnter", "CursorMovedI" }, {
			callback = toggle_ghost_text,
		})
	end,
}
