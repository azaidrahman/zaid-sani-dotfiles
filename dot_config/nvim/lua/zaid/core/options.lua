vim.g.netrw_banner = 0
vim.opt.iskeyword:remove("_")

-- nvim sets the cursor shape. An empty value gives the shape of the terminal,
-- and Rex uses a bar.
vim.opt.guicursor = "n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20"
vim.opt.nu = true
vim.opt.relativenumber = true

vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.autoindent = true
vim.opt.smartindent = true
vim.opt.wrap = false

vim.opt.laststatus = 3
vim.opt.showmode = false -- lualine already shows the mode
vim.opt.cmdheight = 0 -- noice owns cmdline + messages; reclaim the row

vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undodir = os.getenv("HOME") .. "/.vim/undodir"
vim.opt.undofile = true

vim.opt.incsearch = true
vim.opt.inccommand = "split"

vim.opt.ignorecase = true
vim.opt.smartcase = true

vim.opt.termguicolors = true
vim.opt.background = "dark"

vim.opt.scrolloff = 18
vim.opt.signcolumn = "yes"

-- Folding is configured in nvim-ufo plugin (lua/zaid/plugins/nvim-ufo.lua)

-- backspace
vim.opt.backspace = { "start", "eol", "indent" }

--split windows
vim.opt.splitright = true --split vertical window to the right
vim.opt.splitbelow = true --split horizontal window to the bottom

-- prompt to save/discard instead of erroring (E37) when a command would
-- abandon a modified buffer (e.g. fff.nvim opening a file via :edit)
vim.opt.confirm = true

vim.opt.isfname:append("@-@")
vim.opt.updatetime = 50

-- clipboard
vim.opt.clipboard:append("unnamedplus") --use system clipboard as default

-- A Rex pane can show in the Rex app of a different Mac. pbcopy writes only to
-- the clipboard of the Mac that runs nvim. OSC 52 sends the copy to the Rex app
-- that shows the pane. Do both. Then the copy gets to the Mac that you use, and
-- "p" in nvim can read it back with pbpaste.
if vim.env.TERM_PROGRAM == "rex" then
	local send_osc52 = require("vim.ui.clipboard.osc52").copy("+")
	local function copy(lines, regtype)
		send_osc52(lines, regtype)
		vim.system({ "pbcopy" }, { stdin = table.concat(lines, "\n") })
	end
	vim.g.clipboard = {
		name = "rex",
		copy = { ["+"] = copy, ["*"] = copy },
		paste = { ["+"] = "pbpaste", ["*"] = "pbpaste" },
	}
end

vim.opt.hlsearch = true

-- for easy mouse resizing, just incase
vim.opt.mouse = "a"

-- filetype extensions
vim.filetype.add({
	extension = {
		MD = "markdown",
	},
})

vim.opt.textwidth = 120
