-- prefix+v: special paste. Paste a screenshot into a program on another Mac,
-- for example Claude Code on onyx, from the Rex app on aqua.
--
-- The special_paste action looks at the pane:
--
--   a pane of a Rex host, image  -> send the image to that host, then paste
--                                    its path on that host
--   ssh, image                   -> send the image to the host of ssh, then
--                                    paste its path on that host
--   no image                     -> a normal paste
--   another program              -> a normal paste
--
-- A pane of a Rex host (`rex hosts`) runs on that host. The app sends the key
-- to the Rex of this Mac, with ctx.server set to the label of the host. The
-- action runs here, because this Mac has the clipboard. The upload uses
-- `ssh <label in lowercase>`, for example `ssh onyx` for the host ONYX. Then
-- the Rex of the host pastes the path into the pane.
--
-- scripts/special-paste.sh does the upload, and it does not change the
-- clipboard. CleanShot puts the image and its file on the clipboard. The
-- upload sends the image. A normal paste gives the path of the file on this
-- Mac, and the other Mac does not have that file.
--
-- Claude Code reads a pasted image path as an image. A shell gets the path
-- as text.
--
-- tmux has the same feature on prefix+i (~/.tmux/scripts/clipssh-send.sh).
-- In tmux, you paste the path yourself after the upload.
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

-- call is the API of the server that holds the pane: rex.call on this Mac,
-- or host.call for a Rex host. Both return the result and an error.
local function focused_block(call, session_id)
  local view, err = call("session.view", { session_id = session_id })
  if err ~= nil then error(err, 0) end
  for _, window in ipairs(view.windows or {}) do
    if window.window_id == view.active_window_id then return window.focused_block_id end
  end
end

-- paste_text pastes TEXT into the block, as the app does: the program gets a
-- bracketed paste if it asks for one.
local function paste_text(call, session_id, block_id, text)
  local _, err = call("block.event", {
    session_id = session_id,
    block_id = block_id,
    event = { type = "paste", payload = { text = text } },
  })
  if err ~= nil then error(err, 0) end
end

local function normal_paste()
  rex.client.queue("pane.paste")
end

-- upload runs the script with ARGS. It returns the remote path, or nil if the
-- clipboard holds no image.
local function upload(args)
  local argv = { SCRIPT }
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  local r = rex.exec(argv, { timeout = TIMEOUT })
  if r and r.ok and r.stdout ~= "" then return r.stdout end
  if r and r.code == NO_IMAGE then return nil end
  local why = (r and r.stderr ~= "" and r.stderr)
    or ("the upload script failed (status " .. tostring(r and r.code) .. ")")
  error("special paste: " .. why:gsub("%s+$", ""), 0)
end

-- on_host pastes into a pane of a Rex host. Find the pane first: if the host
-- does not answer, the action stops before the upload.
local function on_host(ctx)
  local ok, host = pcall(rex.server, ctx.server)
  if not ok then error("special paste: Rex cannot reach the host " .. ctx.server .. ".", 0) end
  local block_id = ctx.block_id or focused_block(host.call, ctx.session_id)
  if not block_id then return normal_paste() end
  local path = upload({ "--host", ctx.server:lower() })
  if not path then return normal_paste() end
  paste_text(host.call, ctx.session_id, block_id, path)
end

local function special_paste(ctx)
  if ctx.server then return on_host(ctx) end

  local block_id = ctx.block_id or focused_block(rex.call, ctx.session_id)
  if not block_id then return normal_paste() end

  local process = rex.block.call(TERMINAL, "process", { block_id = block_id }) or {}
  local foreground = process.foreground or {}
  if foreground.name ~= "ssh" or not foreground.pid then return normal_paste() end

  local path = upload({ tostring(foreground.pid) })
  if not path then return normal_paste() end
  paste_text(rex.call, ctx.session_id, block_id, path)
end

rex.action{
  name = "special_paste",
  title = "Special Paste",
  description = "In a pane of a Rex host or an ssh pane, send the clipboard image to the host and paste its path there. Otherwise, do a normal paste.",
  keywords = "paste image screenshot clipboard ssh clipssh upload remote onyx aqua",
  run = special_paste,
}
