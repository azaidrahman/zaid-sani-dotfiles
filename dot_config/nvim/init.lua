require("zaid.core")
require("zaid.lazy")
require("current-theme")
-- require("zaid.terminalpop")

if vim.fn.has("nvim") == 1 and vim.fn.executable("nvr") == 1 then
	vim.env.GIT_EDITOR = "nvr -cc split --remote-wait +'set bufhidden=wipe'"
end

-- local env_file = vim.fn.stdpath("config") .. "/.env"

-- for line in io.lines(env_file) do
-- 	for k, v in string.gmatch(line, "([%w_]+)=([^\n\r]+)") do
-- 		vim.fn.setenv(k, v)
-- 	end
-- end
