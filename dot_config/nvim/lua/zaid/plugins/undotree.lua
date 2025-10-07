return {
    "mbbill/undotree",
    config = function()
        vim.keymap.set("n", "<leader>u", vim.cmd.UndotreeToggle, {desc="Toogle undo tree", noremap=true, silent=true})
    end,
}
