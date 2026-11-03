-- Pick a Bitbucket pull request to review, sync, approve, merge, or open in
-- the browser. This is the Rex copy of tmux prefix+B (~/.tmux/conf.d/keys.conf).
-- tmux uses prefix+p for previous-window, so only Rex uses prefix+p.
--
-- The bb_prs action opens a float in the directory of the focused pane. The
-- float runs the bb-prs program (dot_local/bin/executable_bb-prs). The program
-- starts its refresh as a separate process, so the refresh goes on after the
-- float closes.
--
-- To keep the float as a regular pane, use the dock_float action (dock.lua).
--
-- To run the action without the key, use `rex do bb_prs`.

local TERMINAL = "com.superlogical.terminal"
local SHELL = "com.superlogical.terminal.shell"

local dock = require("dock")

-- The float can run on a host that did not load this file. The home
-- directory is not the same on each Mac. Thus a shell finds the program on
-- the host that runs the float. BB_PRS_POPUP makes the program wait for a key
-- after an error, so the float shows the message. A test sets REX_BB_PRS to
-- a stub or to its own build. The float gets the environment of the server, so
-- REX_SESSION is not set there. The command gets the session id as $1 and sets
-- REX_SESSION. The program then opens a new tab (the conflict check, key c) in
-- the same session.
local COMMAND = 'BB_PRS_POPUP=1 REX_SESSION="$1" exec "${REX_BB_PRS:-$HOME/.local/bin/bb-prs}"'

-- The float fills this fraction of the window. This is the size of the tmux
-- popup (~/.tmux/scripts/popups/git-popup-size.sh).
local WIDTH, HEIGHT = 0.98, 0.96

local function open(ctx)
  local view = assert(rex.session.view{ session_id = ctx.session_id })
  local block_id = ctx.block_id
  if not block_id then
    for _, window in ipairs(view.windows or {}) do
      if window.window_id == view.active_window_id then
        block_id = window.focused_block_id
      end
    end
  end
  if not block_id then error("bb_prs: no pane has focus", 0) end

  local process = rex.block.call(TERMINAL, "process", { block_id = block_id }) or {}
  local cwd = (process.foreground or {}).cwd
  if not cwd then error("bb_prs: no directory for the pane", 0) end

  local result = assert(rex.session.new_layer{
    session_id = ctx.session_id,
    window_id = view.active_window_id,
    bounds = { (1 - WIDTH) / 2, (1 - HEIGHT) / 2, WIDTH, HEIGHT },
    focus = true,
    layout = rex.layout.block{
      flavor = SHELL,
      label = "Bitbucket PRs",
      options = {
        command = { "sh", "-c", COMMAND, "bb-prs", ctx.session_id or "" },
        cwd = cwd,
      },
    },
  })
  dock.remember((result.block_ids or {})[1], block_id)
  return result
end

rex.action{
  name = "bb_prs",
  title = "Bitbucket PRs",
  description = "Pick a Bitbucket PR to review, sync, approve, merge, or open in the browser.",
  keywords = "bitbucket pr pull request review merge approve",
  run = function(ctx) return open(ctx) end,
}
