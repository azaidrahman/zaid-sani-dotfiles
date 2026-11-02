-- Start a `rex do` script that runs beside the Rex server, such as the
-- poller of the status center or the watcher of closed tabs.

local M = {}

-- start runs `rex do ARGS...` each time the server loads the configuration.
-- The script must exit by itself when another copy of it runs already.
--
-- The script needs the rex binary of the server. A command that this file
-- runs is a child of the process that loads the file, so the parent of the
-- command is the server. `rex config check` loads the file in the CLI, and
-- the parent of the command is not a server. Thus a check starts no script.
--
-- The script gets the path of the binary in REX_BIN, so that it can start
-- other rex commands.
function M.start(args)
  local ps = rex.exec({ "/bin/sh", "-c", 'ps -o args= -p "$PPID"' }, { timeout = 5 })
  local rex_bin = ps and ps.ok and ps.stdout:match("^(.-/rex) server run")
  if not rex_bin then return end
  local argv = { rex_bin, "--autostart=false", "do" }
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  rex.exec.start(argv, {
    detach = true, stdout = false, stderr = false, env = { REX_BIN = rex_bin },
  })
end

return M
