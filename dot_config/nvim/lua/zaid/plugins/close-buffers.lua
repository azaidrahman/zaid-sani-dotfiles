return {
	"kazhala/close-buffers.nvim",
	enabled = true,
	config = function()
		require("close_buffers").setup({
			filetype_ignore = {}, -- Filetype to ignore when running deletions
			file_glob_ignore = {}, -- File name glob pattern to ignore when running deletions (e.g. '*.md')
			file_regex_ignore = {}, -- File name regex pattern to ignore when running deletions (e.g. '.*[.]md')
			preserve_window_layout = { "this", "nameless" }, -- Types of deletion that should preserve the window layout
			next_buffer_cmd = nil, -- Custom function to retrieve the next buffer when preserving window layout
		})
	end,
}

-- :BDelete! hidden
-- :BDelete nameless
-- :BDelete this
-- :BDelete 1
-- :BDelete regex='.*[.].md'
--
-- :BWipeout! all
-- :BWipeout other
-- :BWipeout hidden glob=*.lua
