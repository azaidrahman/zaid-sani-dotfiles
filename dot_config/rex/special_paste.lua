-- prefix+v: special paste. Paste a screenshot into a program on the other
-- side of ssh, for example Claude Code on onyx in `ssh onyx` from aqua.
--
-- The special_paste action looks at the foreground program of the pane:
--
--   ssh, image on the clipboard  -> send the image to the host of ssh, then
--                                    paste its path on that host
--   ssh, no image                -> a normal paste
--   another program              -> a normal paste
--
-- scripts/special-paste.sh does the upload. It uses the options of the ssh
-- process, and it does not change the clipboard. Claude Code reads a pasted
-- image path as an image. A shell gets the path as text.
--
-- tmux has the same feature on prefix+i (~/.tmux/scripts/clipssh-send.sh).
-- In tmux, you paste the path yourself after the upload.
--
-- If you open the pane through a Rex host (`rex hosts`) and not through ssh,
-- this action does a normal paste. The pane then runs on the other Mac, and
-- that Mac cannot read the clipboard of this Mac.
--
-- To run the action without the key, use `rex do special_paste`.

local TERMINAL = "com.superlogical.terminal"
local CONFIG_HOME = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")

-- rex.exec runs the script on this Mac, because this Mac has the clipboard.
-- A test sets REX_SPECIAL_PASTE to the script of its checkout.
local SCRIPT = os.getenv("REX_SPECIAL_PASTE") or (CONFIG_HOME .. "/rex/scripts/special-paste.sh")

-- The script exits with this status if the clipboard holds no image.
local NO_IMAGE = 3

-- A large screenshot over a slow link can take some seconds.
local TIMEOUT = 30

local function focused_block(session_id)
  local view = assert(rex.session.view{ session_id = session_id })
  for _, window in ipairs(view.windows or {}) do
    if window.window_id == view.active_window_id then return window.focused_block_id end
  end
end

-- paste_text pastes TEXT into the block, as the app does: the program gets a
-- bracketed paste if it asks for one.
local function paste_text(ctx, block_id, text)
  local _, err = rex.call("block.event", {
    session_id = ctx.session_id,
    block_id = block_id,
    event = { type = "paste", payload = { text = text } },
  })
  if err ~= nil then error(err, 0) end
end

local function normal_paste()
  rex.client.queue("pane.paste")
end

local function special_paste(ctx)
  local block_id = ctx.block_id or focused_block(ctx.session_id)
  if not block_id then return normal_paste() end

  local process = rex.block.call(TERMINAL, "process", { block_id = block_id }) or {}
  local foreground = process.foreground or {}
  if foreground.name ~= "ssh" or not foreground.pid then return normal_paste() end

  local r = rex.exec({ SCRIPT, tostring(foreground.pid) }, { timeout = TIMEOUT })
  if r and r.ok and r.stdout ~= "" then return paste_text(ctx, block_id, r.stdout) end
  if r and r.code == NO_IMAGE then return normal_paste() end

  local why = (r and r.stderr ~= "" and r.stderr)
    or ("the upload script failed (status " .. tostring(r and r.code) .. ")")
  error("special paste: " .. why:gsub("%s+$", ""), 0)
end

rex.action{
  name = "special_paste",
  title = "Special Paste",
  description = "In an ssh pane, send the clipboard image to the host and paste its path there. Otherwise, do a normal paste.",
  keywords = "paste image screenshot clipboard ssh clipssh upload remote onyx aqua",
  run = special_paste,
}
