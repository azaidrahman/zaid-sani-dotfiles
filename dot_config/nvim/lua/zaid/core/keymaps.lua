local yank = require 'zaid.core.yank'
local opts = { noremap = true, silent = true }
-- noremap just means that the keymap stops at that trigger and doesnt get retriggered, or in other words, it doesnt get overridden
local descopts = function(desc)
    return {noremap=true,silent=true,desc=desc}
end
vim.g.mapleader = " "
vim.g.maplocalleader = " "

vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "moves lines down in visual selection" })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "moves lines up in visual selection" })

vim.keymap.set("n", "J", "mzJ`z", { desc = "Join lines (cursor stays)" })
vim.keymap.set("n", "<C-d>", "<C-d>zz", { desc = "move down in buffer with cursor centered" })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { desc = "move up in buffer with cursor centered" })
vim.keymap.set("n", "n", "nzzzv", { desc = "Next search result (centered)" })
vim.keymap.set("n", "N", "Nzzzv", { desc = "Prev search result (centered)" })

vim.keymap.set("v", "<", "<gv", opts)
vim.keymap.set("v", ">", ">gv", opts)

vim.keymap.set("n", "<leader>bv","ggVG", descopts("Select all in buffer") )

vim.keymap.set("n", "<leader>bd", "<cmd>BDelete this<CR>", descopts("[B]uffer [D]elete"))
vim.keymap.set("n", "<leader>bo", "<cmd>BDelete other<CR>", descopts("[B]uffer [O]ther"))
vim.keymap.set("n", "<leader>bn", "<cmd>BDelete nameless<CR>", descopts("[B]uffer [N]ameless"))

vim.keymap.set("n", "<leader>qq", ":q<CR>", opts)
vim.keymap.set("n", "<leader>qc", ":q!<CR>", opts)
vim.keymap.set("n", "<leader>qw", ":w<CR>", opts)

vim.keymap.set("n", "<leader>pd", function() Snacks.dashboard() end, descopts("Open dashboard"))

-- remember yanked
vim.keymap.set("v", "p", '"_dp', opts)

-- Copies or Yank to system clipboard
vim.keymap.set("n", "<leader>yy", [["+Y]], { desc = "Yank line to system clipboard" })

-- yank path
vim.keymap.set('n', '<leader>ya', function()
  yank.yank_path(yank.get_buffer_absolute(), 'absolute')
end, { desc = '[Y]ank [A]bsolute path to clipboard' })

vim.keymap.set('n', '<C-g>', function()
  local path = vim.bo.filetype == 'oil'
    and require('oil').get_current_dir()
    or yank.get_buffer_absolute()

  vim.cmd('file')              -- native <C-g> output
  vim.fn.setreg('+', path)
  vim.notify(path, vim.log.levels.INFO, { title = 'Yanked path' })
end, { desc = 'Show + yank current buffer/oil path' })

vim.keymap.set('n', '<leader>yr', function()
  yank.yank_path(yank.get_buffer_cwd_relative(), 'relative')
end, { desc = '[Y]ank [R]elative path to clipboard' })

vim.keymap.set('v', '<leader>ya', function()
  yank.yank_visual_with_path(yank.get_buffer_absolute(), 'absolute')
end, { desc = '[Y]ank selection with [A]bsolute path' })

vim.keymap.set('v', '<leader>yr', function()
  yank.yank_visual_with_path(yank.get_buffer_cwd_relative(), 'relative')
end, { desc = '[Y]ank selection with [R]elative path' })

vim.keymap.set("n", "<Esc>", ":nohl<CR>", { desc = "Clear search hl", silent = true })

-- Disable <Esc> to build the habit of using <C-c> to escape
vim.keymap.set("i", "<Esc>", "<nop>", { desc = "Disabled — use <C-c>" })
vim.keymap.set("v", "<Esc>", "<nop>", { desc = "Disabled — use <C-c>" })
vim.keymap.set("s", "<Esc>", "<nop>", { desc = "Disabled — use <C-c>" })

-- Unmaps Q in normal mode
vim.keymap.set("n", "Q", "<nop>", { desc = "Disabled" })

-- prevent x delete from registering when next paste
vim.keymap.set("n", "x", '"_x', { desc = "Delete char (no register)" })

-- tab stuff (standalone only — tmux windows are the workspace unit inside tmux)
require("zaid.core.env").when_standalone(function()
    vim.keymap.set("n", "<leader>to", "<cmd>tabnew<CR>", { desc = "Open new tab" })
    vim.keymap.set("n", "<leader>tx", "<cmd>tabclose<CR>", { desc = "Close current tab" })
    vim.keymap.set("n", "<leader>tn", "<cmd>tabn<CR>", { desc = "Go to next tab" })
    vim.keymap.set("n", "<leader>tp", "<cmd>tabp<CR>", { desc = "Go to previous tab" })
    vim.keymap.set("n", "<leader>tf", "<cmd>tabnew %<CR>", { desc = "Open current buffer in new tab" })
end)

-- buffer stuff (MRU order, not buffer-number order)
local buffer_mru = require("zaid.core.buffer_mru")
vim.keymap.set("n", "<S-h>", buffer_mru.jump_recent, { desc = "Go to last-opened buffer" })
vim.keymap.set("n", "<S-l>", buffer_mru.jump_oldest, { desc = "Go to furthest-back buffer" })

-- window stuff: past the edge of nvim, the keys go to tmux or Rex panes
local navigator = require("zaid.core.navigator")
vim.keymap.set("n", "<C-h>", function() navigator.move("h") end, { desc = "Go to left window or pane" })
vim.keymap.set("n", "<C-j>", function() navigator.move("j") end, { desc = "Go to lower window or pane" })
vim.keymap.set("n", "<C-k>", function() navigator.move("k") end, { desc = "Go to upper window or pane" })
vim.keymap.set("n", "<C-l>", function() navigator.move("l") end, { desc = "Go to right window or pane" })
vim.keymap.set("n", "<C-\\>", function() navigator.move("p") end, { desc = "Go to last window or pane" })

-- get current buffers directory
vim.keymap.set("n", "<leader>hd", function()
    print(vim.fn.expand("%:p:h"))
end, descopts("Show current buffer directory")
)


vim.keymap.set("v", "<leader>hs", function()
    vim.cmd('normal! "xy')
    vim.cmd('execute "help " . @x')
end, { noremap = true, silent = true, desc = "Search under cursor in help" })

-- Toggle LSP diagnostics visibility (starts false to match lspconfig's virtual_text = false)
local isLspDiagnosticsVisible = false
vim.keymap.set("n", "<leader>lx", function()
	isLspDiagnosticsVisible = not isLspDiagnosticsVisible
	vim.diagnostic.config({
		virtual_text = isLspDiagnosticsVisible,
		underline = isLspDiagnosticsVisible,
	})
end, { desc = "Toggle LSP diagnostics" })

local makerun = require("zaid.core.makerun")
vim.keymap.set("n", "<leader>qr", makerun.run, descopts("Pick Makefile target, run in float"))
-- <leader>qg is now bound by zaid/plugins/overseer.lua (language-agnostic run)
vim.keymap.set("n", "<leader>qo", makerun.open, descopts("Reopen hidden run float"))
vim.keymap.set("n", "<leader>o", makerun.promote, descopts("Promote run float to split"))

vim.keymap.set("n", "<leader>pq", "<cmd>copen<CR>", descopts("Open quickfix list") )

-- `q` closes the quickfix window from anywhere (e.g. the editor after a
-- <leader>qg run). Falls through to normal macro recording when no quickfix
-- window is open, so `q`'s default behaviour is preserved.
vim.keymap.set("n", "q", function()
	for _, win in ipairs(vim.fn.getwininfo()) do
		if win.quickfix == 1 and win.loclist == 0 then
			vim.cmd("cclose")
			return
		end
	end
	vim.api.nvim_feedkeys("q", "n", false)
end, descopts("Close quickfix if open, else record macro"))

vim.keymap.set("n","<leader>gn","<cmd>Neogit<cr>",descopts("Open neogit"))

vim.keymap.set("n", "<leader>hm", "<cmd>Noice history<cr>", descopts("[H]istory of [M]essages (noice)"))


