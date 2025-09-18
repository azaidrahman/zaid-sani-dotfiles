local opts = { noremap = true, silent = true }
-- noremap just means that the keymap stops at that trigger and doesnt get retriggered, or in other words, it doesnt get overridden
local descopts = function(desc)
    return {noremap=true,silent=true,desc=desc}
end
vim.g.mapleader = " "
vim.g.maplocalleader = " "

vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "moves lines down in visual selection" })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "moves lines up in visual selection" })

vim.keymap.set("n", "J", "mzJ`z")
vim.keymap.set("n", "<C-d>", "<C-d>zz", { desc = "move down in buffer with cursor centered" })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { desc = "move up in buffer with cursor centered" })
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")

vim.keymap.set("v", "<", "<gv", opts)
vim.keymap.set("v", ">", ">gv", opts)

vim.keymap.set("n", "<leader>bv","ggVG", descopts("Select all in buffer") )

vim.keymap.set("n", "<leader>qq", ":q<CR>", opts)
vim.keymap.set("n", "<leader>qc", ":q!<CR>", opts)
vim.keymap.set("n", "<leader>qs", ":w<CR>", opts)

vim.keymap.set("n", "<leader>ys", ":h nvim-surround.usage<CR>", opts)

-- the how it be paste
-- vim.keymap.set("x", "<leader>p", [["_dP]])
vim.keymap.set("n", "<leader>pd", ":lua Snacks.dashboard()<CR>", opts)

-- remember yanked
vim.keymap.set("v", "p", '"_dp', opts)

-- Copies or Yank to system clipboard
vim.keymap.set("n", "<leader>Y", [["+Y]], opts)

-- leader d delete wont remember as yanked/clipboard when delete pasting
-- vim.keymap.set({ "n", "v" }, "<leader>d", [["_d]])

-- ctrl c as escape cuz Im lazy to reach up to the esc key
-- vim.keymap.set("i", "<C-c>", "<Esc>")
vim.keymap.set("n", "<Esc>", ":nohl<CR>", { desc = "Clear search hl", silent = true })
-- format without prettier using the built in

-- vim.keymap.set("n", "<leader>f", vim.lsp.buf.format)

-- Unmaps Q in normal mode
vim.keymap.set("n", "Q", "<nop>")

-- Stars new tmux session from in here
-- vim.keymap.set("n", "<C-f>", "<cmd>silent !tmux neww tmux-sessionizer<CR>")

-- prevent x delete from registering when next paste
vim.keymap.set("n", "x", '"_x', opts)

-- Replace the word cursor is on globally
-- vim.keymap.set(
--     "n",
--     "<leader>s",
--     [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]],
--     { desc = "Replace word cursor is on globally" }
-- )

-- Executes shell command from in here making file executable
-- vim.keymap.set("n", "<leader>x", "<cmd>!chmod +x %<CR>", { silent = true, desc = "makes file executable" })

-- Hightlight yanking

-- tab stuff
-- vim.keymap.set("n", "<leader>to", "<cmd>tabnew<CR>") -- open new tab
-- vim.keymap.set("n", "<leader>tx", "<cmd>tabclose<CR>") -- close current tab
-- vim.keymap.set("n", "<leader>tn", "<cmd>tabn<CR>") -- go to next
-- vim.keymap.set("n", "<leader>tp", "<cmd>tabp<CR>") -- go to pre
-- vim.keymap.set("n", "<leader>tf", "<cmd>tabnew %<CR>") -- open current tab in new tab

-- buffer stuff
vim.keymap.set("n", "<S-l>", ":bnext<CR>", { noremap = true, silent = true, desc = "Move to next buffer" })
vim.keymap.set("n", "<S-h>", ":bprevious<CR>", { noremap = true, silent = true, desc = "Move to previous buffer" })

vim.keymap.set("v", "<leader>hs", function()
    vim.cmd('normal! "xy')
    vim.cmd('execute "help " . @x')
end, { noremap = true, silent = true, desc = "Search under cursor in help" })

-- -- split management (wont use splits cus i just use tmux)
-- vim.keymap.set("n", "<leader>sv", "<C-w>v", { desc = "Split window vertically" })
-- -- split window vertically
-- vim.keymap.set("n", "<leader>sh", "<C-w>s", { desc = "Split window horizontally" })
-- -- split window horizontally
-- vim.keymap.set("n", "<leader>se", "<C-w>=", { desc = "Make splits equal size" }) -- make split windows equal width & height
-- -- close current split window
-- vim.keymap.set("n", "<leader>sx", "<cmd>close<CR>", { desc = "Close current split" })

-- Copy filepath to the clipboard
vim.keymap.set("n", "<leader>fp", function()
	local filePath = vim.fn.expand("%:~") -- Gets the file path relative to the home directory
	vim.fn.setreg("+", filePath) -- Copy the file path to the clipboard register
	print("File path copied to clipboard: " .. filePath) -- Optional: print message to confirm
end, { desc = "Copy file path to clipboard" })

-- Toggle LSP diagnostics visibility
local isLspDiagnosticsVisible = true
vim.keymap.set("n", "<leader>lx", function()
	isLspDiagnosticsVisible = not isLspDiagnosticsVisible
	vim.diagnostic.config({
		virtual_text = isLspDiagnosticsVisible,
		underline = isLspDiagnosticsVisible,
	})
end, { desc = "Toggle LSP diagnostics" })


-- vim.keymap.set("n", "<leader>rp", function()
-- 	vim.cmd("w")
-- 	vim.cmd("!clear && python3 %")
-- end, { desc = "Run Python script", noremap = true })
--
-- recommended mappings
-- resizing splits
-- these keymaps will also accept a range,
-- for example `10<A-h>` will `resize_left` by `(10 * config.default_amount)`
--
