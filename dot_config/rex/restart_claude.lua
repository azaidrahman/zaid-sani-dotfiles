-- Restart Claude. This is the Rex copy of tmux prefix+A
-- (~/.tmux/scripts/restart-claude-pane.sh).
--
-- The restart_claude action stops the Claude session in a pane, and resumes
-- the same conversation in a new Claude process. Use it after a Claude Code
-- update: the new process loads the new version.
--
-- Steps:
--   1. Find the claude process of the pane. If there is none, the action
--      fails and shows a message.
--   2. Read the session id from ~/.claude/sessions/<pid>.json. Claude writes
--      this file for each process. closed-tabs-watcher.lua reads it too.
--   3. Stop claude with SIGTERM (SIGKILL after 5 seconds). Then type the
--      resume command into the shell that started claude.
--
-- If claude is the program of the pane, no shell waits below it, and the pane
-- closes when claude stops. Thus the action first opens a shell beside the
-- pane. When the old pane closes, the shell gets its space, and the action
-- types the command into the shell.
--
-- The new command uses the same launcher as before. If the old process had
-- ANTHROPIC_BASE_URL in its environment, it came from `cv` (the LiteLLM
-- proxy), so the new one starts with `cv` too. Only a small set of flags
-- carries over (see launch_command).
--
-- To run the action without the key, use `rex do restart_claude`. Add
-- block_id=<id> to restart Claude in a pane that does not have focus.

local TERMINAL = "com.superlogical.terminal"
local SHELL = "com.superlogical.terminal.shell"
local CLAUDE_DIR = os.getenv("CLAUDE_CONFIG_DIR") or (os.getenv("HOME") .. "/.claude")

-- After SIGTERM, wait this number of tenths of a second for claude to stop.
local STOP_TENTHS = 50

-- STOP_SCRIPT stops the process $1. It waits $2 tenths of a second, then
-- sends SIGKILL. It exits with 0 only if the process stopped.
local STOP_SCRIPT = [[
kill -TERM "$1" 2>/dev/null
i=0
while kill -0 "$1" 2>/dev/null; do
	i=$((i + 1))
	if [ "$i" -ge "$2" ]; then
		kill -KILL "$1" 2>/dev/null
		sleep 0.3
		break
	fi
	sleep 0.1
done
! kill -0 "$1" 2>/dev/null
]]

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

-- ps runs ps with ARGS and returns its output, or "" if ps fails.
local function ps(args)
  local argv = { "/bin/ps" }
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  local r = rex.exec(argv, { timeout = 5 })
  return (r and r.ok and r.stdout) or ""
end

-- find_claude returns the outermost claude process of a terminal, or nil.
-- Claude can be the foreground process, or the parent of a tool that Claude
-- runs. The list of ancestors goes up from the parent of the foreground
-- process, so the last claude in the chain is the outermost one.
local function find_claude(process)
  local chain = { process.foreground }
  for _, p in ipairs(process.ancestors or {}) do chain[#chain + 1] = p end
  local found
  for _, p in ipairs(chain) do
    if p.name == "claude" and p.pid then found = p end
  end
  return found
end

-- launch_command returns the command that resumes the session SID. WORDS are
-- the words of the old command line, after the program name. USE_CV is true
-- when the old process came from `cv`. If SID is nil, the command starts a
-- new session.
--
-- ps prints the old command line without its quotes. Thus a prompt argument
-- and a flag value cannot be told apart in general, and only these flags
-- carry over.
local function launch_command(sid, use_cv, words)
  local keep, i = {}, 1
  while i <= #words do
    local a = words[i]
    if a == "--model" or a == "--permission-mode" then
      if words[i + 1] then
        keep[#keep + 1] = a
        keep[#keep + 1] = words[i + 1]
      end
      i = i + 2
    else
      if a == "--dangerously-skip-permissions"
          or a:match("^%-%-model=") or a:match("^%-%-permission%-mode=") then
        keep[#keep + 1] = a
      elseif a == "--allow-dangerously-skip-permissions" and not use_cv then
        -- cv adds this flag itself.
        keep[#keep + 1] = a
      end
      i = i + 1
    end
  end
  local cmd = use_cv and "cv" or "claude"
  if #keep > 0 then cmd = cmd .. " " .. table.concat(keep, " ") end
  if sid then cmd = cmd .. " --resume " .. sid end
  return cmd
end

local function restart(ctx, args)
  local block_id = args.block_id or ctx.block_id
  if not block_id then error("Select a pane that runs Claude.", 0) end

  -- 1. Find claude.
  local process = rex.block.call(TERMINAL, "process", { block_id = block_id })
  local claude = process and find_claude(process)
  if not claude then error("This pane is not running a Claude session.", 0) end
  local pid = tostring(claude.pid)

  -- 2. Find the session. A session that has no transcript yet has no
  -- messages, so a fresh start loses nothing. Claude keeps the transcript
  -- under a directory named for the directory where it started.
  local text = read_file(CLAUDE_DIR .. "/sessions/" .. pid .. ".json")
  local info = text and rex.json.decode(text)
  if not (info and info.sessionId) then
    error("Claude (pid " .. pid .. ") has no session file in " .. CLAUDE_DIR .. "/sessions.", 0)
  end
  local cwd = info.cwd or claude.cwd
  local project = (cwd or ""):gsub("[^%w]", "-")
  local sid
  if file_exists(CLAUDE_DIR .. "/projects/" .. project .. "/" .. info.sessionId .. ".jsonl") then
    sid = info.sessionId
  end

  local words = {}
  for w in ps({ "-p", pid, "-o", "args=" }):gmatch("%S+") do words[#words + 1] = w end
  if #words == 0 then error("Claude stopped before the restart (pid " .. pid .. ").", 0) end
  table.remove(words, 1)
  local env = ps({ "eww", "-p", pid, "-o", "command=" })
  local cmd = launch_command(sid, env:find(" ANTHROPIC_BASE_URL=", 1, true) ~= nil, words)

  -- 3. Restart. If claude is the program of the pane, put a new shell
  -- beside the pane before claude stops, while the pane is still there.
  local target = block_id
  local direct = process.child and process.child.pid == claude.pid
  if direct then
    local split, err = rex.session.new_split{
      anchor_id = block_id,
      direction = "horizontal",
      side = "after",
      -- From a key, the pane has focus. Give the focus to the new shell.
      focus = args.block_id == nil,
      layout = rex.layout.block{ flavor = SHELL, options = { cwd = cwd } },
    }
    if not split then error(err, 0) end
    target = split.block_ids[1]
  end

  local stopped = rex.exec({ "/bin/sh", "-c", STOP_SCRIPT, "sh", pid, tostring(STOP_TENTHS) },
    { timeout = 15 })
  if not (stopped and stopped.ok) then error("Claude did not stop (pid " .. pid .. ").", 0) end

  if direct then
    -- Rex keeps a pane open after a quick failure. Close it, so that the new
    -- shell gets its space. If the pane closed already, the call fails.
    rex.call("block.close", { session_id = ctx.session_id, block_id = block_id })
  end
  local _, err = rex.block.call(TERMINAL, "write", { block_id = target, data = cmd .. "\r" })
  if err ~= nil then error(err, 0) end
  return { block_id = target, command = cmd }
end

rex.action{
  name = "restart_claude",
  title = "Restart Claude",
  description = "Stop the Claude session in this pane and resume the same conversation, for example after a Claude Code update.",
  keywords = "claude restart reload resume update",
  args = { block_id = "string?" },
  run = restart,
}
