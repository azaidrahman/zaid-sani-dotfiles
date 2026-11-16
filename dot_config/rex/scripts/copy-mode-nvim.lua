-- The nvim setup for Rex copy mode.
-- Run it as: nvim -R -n --noplugin -u <this file> + -
-- Rex sends the text of a pane to nvim on standard input.
-- The argument + puts the cursor on the last line, which is the current screen.
--
-- The option -u makes nvim skip the config of the user. The option --noplugin
-- skips the plugins of the user. This is on purpose.
-- Copy mode must start fast. It must work on each host, also on a host that
-- has no plugins. The config of the user can also write files, and the pane
-- text must not go to disk.

-- Copy with OSC 52. The terminal then sets the clipboard, also over SSH.
-- The string form, vim.g.clipboard = 'osc52', needs Neovim 0.12.
-- This file uses the table form. It loads the OSC 52 module that Neovim bundles.
local osc52 = require('vim.ui.clipboard.osc52')
vim.g.clipboard = {
  name = 'OSC 52',
  copy = { ['+'] = osc52.copy('+'), ['*'] = osc52.copy('*') },
  paste = { ['+'] = osc52.paste('+'), ['*'] = osc52.paste('*') },
}
vim.opt.clipboard = 'unnamedplus'

-- Do not write state files. They can hold pane text.
vim.opt.undofile = false
vim.opt.shada = ''
vim.opt.swapfile = false

-- The buffer is read-only. Copy mode only reads.
vim.bo.modifiable = false
vim.opt.readonly = true

-- q quits without a copy.
vim.keymap.set('n', 'q', '<Cmd>qa!<CR>')
-- Visual y copies the selection and quits.
vim.keymap.set('x', 'y', '"+y<Cmd>qa!<CR>')

-- Load flash.nvim only if it is on disk. Do not fail if it is missing.
local flash_dir = vim.fn.stdpath('data') .. '/lazy/flash.nvim'
if vim.uv.fs_stat(flash_dir) then
  vim.opt.runtimepath:append(flash_dir)
  require('flash').setup({})
  vim.keymap.set({ 'n', 'x', 'o' }, 'gs', function()
    require('flash').jump()
  end)
end
