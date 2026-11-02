-- Review the changes of a git worktree in tuicr. This is the Rex copy of tmux
-- prefix+e (~/.tmux/scripts/popups/claude-diff-review.sh).
--
-- The diff_review action opens a float in the directory of the focused pane.
-- The float runs scripts/diff-review.sh. The script does the same checks as
-- the tmux script:
--
--   not a git work tree      -> a message in the float
--   more than one worktree   -> pick a worktree in fzf, then `tuicr -w` there
--   one worktree, changes    -> `tuicr -w` in the directory of the pane
--   one worktree, no changes -> a message in the float
--
-- To keep the float as a regular pane, use the dock_float action (dock.lua).
-- The pane goes on the right of the pane where you pressed the key.
--
-- To run the action without the key, use `rex do diff_review`.

local TERMINAL = "com.superlogical.terminal"
local SHELL = "com.superlogical.terminal.shell"

local dock = require("dock")

-- The float can run on a host that did not load this file. The home
-- directory is not the same on each Mac. Thus a shell finds the script on the
-- host that runs the float. See tab_picker.lua. A test sets REX_DIFF_REVIEW
-- to the script of its checkout.
local GATE = 'exec "${REX_DIFF_REVIEW:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/scripts/diff-review.sh}" "$@"'

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
  if not block_id then error("diff_review: no pane has focus", 0) end

  local process = rex.block.call(TERMINAL, "process", { block_id = block_id }) or {}
  local cwd = (process.foreground or {}).cwd
  if not cwd then error("diff_review: no directory for the pane", 0) end

  local result = assert(rex.session.new_layer{
    session_id = ctx.session_id,
    window_id = view.active_window_id,
    bounds = { (1 - WIDTH) / 2, (1 - HEIGHT) / 2, WIDTH, HEIGHT },
    focus = true,
    layout = rex.layout.block{
      flavor = SHELL,
      label = "tuicr",
      options = {
        -- The login shell gives the PATH that finds git, fzf, jq, rex and
        -- tuicr. The gate types `cd` into the pane of block_id, if a shell
        -- owns it.
        command = { "sh", "-c", GATE, "diff-review.sh", cwd, ctx.session_id or "", block_id },
        cwd = cwd,
      },
    },
  })
  dock.remember((result.block_ids or {})[1], block_id)
  return result
end

rex.action{
  name = "diff_review",
  title = "Review Worktree Changes",
  description = "Review the uncommitted changes of a git worktree in tuicr. If the repo has more than one worktree, pick one first.",
  keywords = "tuicr diff review worktree git changes",
  run = function(ctx) return open(ctx) end,
}
