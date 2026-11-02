-- Edit a draft that Claude proposed. This is the Rex copy of tmux prefix+y
-- (~/.tmux/scripts/popups/commit-msg-popup.sh).
--
-- Claude writes the commit message to CLAUDE_COMMIT_MSG and the pull request
-- draft to CLAUDE_PR_MSG, in the git dir of the repo or worktree. The
-- commit_draft action opens a float in the directory of the focused pane. The
-- float runs scripts/commit-draft.sh. If only one draft exists, its editor
-- opens. If both exist, the float asks which one to edit.
--
-- The commit draft opens `git commit -v` in nvim, with the staged diff below
-- the message. :wq commits. :cq aborts and keeps your edits for Claude. The
-- pull request draft opens in nvim. :w saves it for Claude.
--
-- To keep the float as a regular pane, use the dock_float action (dock.lua).
-- The pane goes on the right of the pane where you pressed the key.
--
-- To run the action without the key, use `rex do commit_draft`.

local TERMINAL = "com.superlogical.terminal"
local SHELL = "com.superlogical.terminal.shell"

local dock = require("dock")

-- The float can run on a host that did not load this file. The home
-- directory is not the same on each Mac. Thus a shell finds the script on the
-- host that runs the float. See tab_picker.lua. A test sets REX_COMMIT_DRAFT
-- to the script of its checkout.
local GATE = 'exec "${REX_COMMIT_DRAFT:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/scripts/commit-draft.sh}" "$@"'

-- The float fills this fraction of the window. The diff below the message
-- needs space, as in the tmux popup (git-popup-size.sh).
local WIDTH, HEIGHT = 0.95, 0.92

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
  if not block_id then error("commit_draft: no pane has focus", 0) end

  local process = rex.block.call(TERMINAL, "process", { block_id = block_id }) or {}
  local cwd = (process.foreground or {}).cwd
  if not cwd then error("commit_draft: no directory for the pane", 0) end

  local result = assert(rex.session.new_layer{
    session_id = ctx.session_id,
    window_id = view.active_window_id,
    bounds = { (1 - WIDTH) / 2, (1 - HEIGHT) / 2, WIDTH, HEIGHT },
    focus = true,
    layout = rex.layout.block{
      flavor = SHELL,
      label = "Draft",
      options = {
        -- The login shell gives the PATH that finds git and nvim.
        command = { "sh", "-c", GATE, "commit-draft.sh", cwd },
        cwd = cwd,
      },
    },
  })
  dock.remember((result.block_ids or {})[1], block_id)
  return result
end

rex.action{
  name = "commit_draft",
  title = "Edit Commit or PR Draft",
  description = "Edit the commit message or the pull request draft that Claude proposed for the repo of the focused pane.",
  keywords = "claude commit message pull request pr draft git",
  run = function(ctx) return open(ctx) end,
}
