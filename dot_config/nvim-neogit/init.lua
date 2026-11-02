-- Standalone headless config, launched via NVIM_APPNAME=nvim-neogit.
-- Only Neogit — opens straight to status, quits nvim entirely on close.
-- Used by the tmux prefix+t popup; keeps Neogit out of the main config's
-- eager load path (see zaid.plugins.gitstuff, which lazy-loads it on :Neogit).

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		"--branch=stable",
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "
vim.opt.relativenumber = true
vim.keymap.set("n", "<leader>n", function()
	require("neogit").open()
end, { desc = "Back to Neogit status" })

vim.keymap.set("n", "<leader>qq", ":q<CR>", { noremap = true, silent = true })
vim.keymap.set("n", "<leader>qc", ":q!<CR>", { noremap = true, silent = true })
vim.keymap.set("n", "<leader>qw", ":w<CR>", { noremap = true, silent = true })

-- Window navigation (mirrors main config's Ctrl-hjkl in zaid/core/navigator.lua;
-- no tmux-boundary crossing needed since this popup has no adjacent panes)
vim.keymap.set("n", "<C-h>", "<C-w>h", { silent = true })
vim.keymap.set("n", "<C-j>", "<C-w>j", { silent = true })
vim.keymap.set("n", "<C-k>", "<C-w>k", { silent = true })
vim.keymap.set("n", "<C-l>", "<C-w>l", { silent = true })

require("lazy").setup({
	{
		"folke/tokyonight.nvim",
		priority = 1000,
		lazy = false,
		config = function()
			require("tokyonight").setup({
				style = "night",
				transparent = true,
				on_highlights = function(hl, c)
					hl.NeogitDiffAddHighlight = { bg = "#1b3a2b", fg = c.green }
					hl.NeogitDiffDeleteHighlight = { bg = "#3a1e22", fg = c.red }
					hl.NeogitDiffAddInline = { bg = "#2d4f3a", fg = c.green, bold = true }
					hl.NeogitDiffDeleteInline = { bg = "#5a2a30", fg = c.red, bold = true }
					hl.DiffAdd = { bg = "#1b3a2b", fg = c.fg }
					hl.DiffDelete = { bg = "#3a1e22", fg = c.fg }
				end,
			})
			vim.cmd.colorscheme("tokyonight")
		end,
	},
	{
		"NeogitOrg/neogit",
		dependencies = { "nvim-lua/plenary.nvim", "sindrets/diffview.nvim" },
		lazy = false,
		config = function()
			require("neogit").setup({
				graph_style = "unicode",
				mappings = {
					status = {
						["q"] = function()
							vim.cmd("qa!")
						end,
					},
				},
			})
			require("neogit").open()
		end,
	},
})
