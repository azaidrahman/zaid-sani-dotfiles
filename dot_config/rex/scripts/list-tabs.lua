-- Print the tabs of one Rex server as JSON. The Alfred workflow Rex Tabs runs
-- this script for this Mac. It also runs it for a host when the copy that
-- host-tabs-watcher.lua writes is missing or old.
--
--   rex do ~/.config/rex/scripts/list-tabs.lua --json
--   rex -S HOST do ~/.config/rex/scripts/list-tabs.lua --json
--
-- For the format, see tabs.lua.

local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)") or "./"
local tabs = dofile(dir .. "tabs.lua")

local result, err = tabs.collect{ attach = true }
if not result then error(err) end
return result
