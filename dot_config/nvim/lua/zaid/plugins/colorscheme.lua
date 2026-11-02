return {
	-- NOTE: Rose pine
	{
		"rose-pine/neovim",
		name = "rose-pine",
		lazy = true,
		config = function()
			require("rose-pine").setup({
				variant = "main", -- auto, main, moon, or dawn
				dark_variant = "main", -- main, moon, or dawn
				dim_inactive_windows = false,
				styles = { bold = true, italic = false, transparency = false },
				highlight_groups = {
					ColorColumn = { bg = "#1C1C21" },
					Normal = { bg = "none" },
					Pmenu = { bg = "", fg = "#e0def4" },
					PmenuSel = { bg = "#4a465d", fg = "#f8f5f2" },
					PmenuSbar = { bg = "#191724" },
					PmenuThumb = { bg = "#9ccfd8" },
				},
				enable = {
					terminal = false,
					legacy_highlights = false,
					migrations = true,
				},
			})
		end,
	}, -- NOTE: gruvbox
	{
		"ellisonleao/gruvbox.nvim",
		lazy = true,
		config = function()
			require("gruvbox").setup({
				terminal_colors = true,
				undercurl = true,
				underline = true,
				bold = true,
				italic = {
					strings = false,
					emphasis = false,
					comments = false,
					folds = false,
					operators = false,
				},
				strikethrough = true,
				invert_selection = false,
				invert_signs = false,
				invert_tabline = false,
				invert_intend_guides = false,
				inverse = true,
				contrast = "",
				palette_overrides = {},
				overrides = {
					Pmenu = { bg = "" },
				},
				dim_inactive = false,
				transparent_mode = true,
			})
		end,
	}, -- NOTE: Kanagwa
	{
		"rebelot/kanagawa.nvim",
		lazy = true,
		config = function()
			require("kanagawa").setup({
				compile = false,
				undercurl = true,
				commentStyle = { italic = true },
				functionStyle = {},
				keywordStyle = { italic = false },
				statementStyle = { bold = true },
				typeStyle = {},
				transparent = true,
				dimInactive = false,
				terminalColors = true,
				colors = {
					palette = {},
					theme = {
						wave = {},
						dragon = {},
						all = { ui = { bg_gutter = "none", border = "rounded" } },
					},
				},
				overrides = function(colors)
					local theme = colors.theme
					return {
						NormalFloat = { bg = "#1f2030" },
						FloatBorder = { bg = "#1f2030", fg = "#54546d" },
						FloatTitle = { bg = "#1f2030" },
						Pmenu = {
							fg = theme.ui.shade0,
							bg = "NONE",
							blend = vim.o.pumblend,
						},
						PmenuSel = { fg = "NONE", bg = theme.ui.bg_p2 },
						PmenuSbar = { bg = theme.ui.bg_m1 },
						PmenuThumb = { bg = theme.ui.bg_p2 },
						NormalDark = { fg = theme.ui.fg_dim, bg = theme.ui.bg_m3 },
						LazyNormal = { bg = theme.ui.bg_m3, fg = theme.ui.fg_dim },
						MasonNormal = {
							bg = theme.ui.bg_m3,
							fg = theme.ui.fg_dim,
						},
					}
				end,
				theme = "wave",
				background = {
					dark = "wave",
				},
			})
		end,
	}, -- NOTE: gruber-darker
	{
		"blazkowolf/gruber-darker.nvim",
		lazy = true,
	}, -- NOTE: neosolarized
	{
		"craftzdog/solarized-osaka.nvim",
		lazy = true,
		config = function()
			require("solarized-osaka").setup({
				transparent = true,
				terminal_colors = true,
				styles = {
					comments = { italic = true },
					keywords = { italic = false },
					functions = {},
					variables = {},
					sidebars = "dark",
					floats = "dark",
				},
				sidebars = { "qf", "help" },
				day_brightness = 0.3,
				hide_inactive_statusline = false,
				dim_inactive = false,
				lualine_bold = false,
			})
		end,
	}, -- NOTE : tokyonight
	{
		"folke/tokyonight.nvim",
		name = "folkeTokyonight",
		priority = 1000,
		config = function()
			-- nvim paints its own background. If transparent is true, the
			-- terminal theme shows through, and nvim looks different in each
			-- terminal (Ghostty #002b36, Rex abyssal-trench #06101a).
			local transparent = false
			local bg = "#011628"
			local bg_dark = "#011423"
			local bg_highlight = "#143652"
			local bg_search = "#0A64AC"
			local bg_visual = "#275378"
			local fg = "#CBE0F0"
			local fg_dark = "#B4D0E9"
			local fg_gutter = "#627E97"
			local border = "#547998"

            -- CUSTOM COMMENT
            local comment = "#858470"

			require("tokyonight").setup({
				style = "night",
				transparent = transparent,

				styles = {
					comments = { italic = false },
					keywords = { italic = false },
					sidebars = transparent and "transparent" or "dark",
					floats = transparent and "transparent" or "dark",
				},
				on_highlights = function(hl, c)
					hl.NormalFloat = { bg = "#1f2030" }
					hl.FloatBorder = { bg = "#1f2030", fg = "#54546d" }
					hl.FloatTitle = { bg = "#1f2030" }

					-- tokyonight derives Neogit's whole-line add/delete bg from
					-- diff.add/diff.delete, which blend from green2 (a teal, not a
					-- vivid green) and red1 — reads as blue rather than green/red.
					-- Pin explicit green/red for both the whole-line and word-level
					-- (Inline) hunk highlight groups.
					hl.NeogitDiffAddHighlight = { bg = "#1b3a2b", fg = c.green }
					hl.NeogitDiffDeleteHighlight = { bg = "#3a1e22", fg = c.red }
					hl.NeogitDiffAddInline = { bg = "#2d4f3a", fg = c.green, bold = true }
					hl.NeogitDiffDeleteInline = { bg = "#5a2a30", fg = c.red, bold = true }

					-- Same fix for the raw diff groups diffview.nvim's side-by-side
					-- split (prefix+t → d) links DiffviewDiffAdd/Delete to.
					hl.DiffAdd = { bg = "#1b3a2b", fg = c.fg }
					hl.DiffDelete = { bg = "#3a1e22", fg = c.fg }
				end,
				on_colors = function(colors)
					colors.bg = transparent and colors.none or bg
					colors.bg_dark = transparent and colors.none or bg_dark
					colors.bg_float = transparent and colors.none or bg_dark
					colors.bg_highlight = bg_highlight
					colors.bg_popup = bg_dark
					colors.bg_search = bg_search
					colors.bg_sidebar = transparent and colors.none or bg_dark
					colors.bg_statusline = transparent and colors.none or bg_dark
					colors.bg_visual = bg_visual
					colors.border = border
					colors.fg = fg
					colors.fg_dark = fg_dark
					colors.fg_float = fg
					colors.fg_gutter = fg_gutter
					colors.fg_sidebar = fg_dark
                    colors.comment = comment
				end,
			})
		end,
	},
}
