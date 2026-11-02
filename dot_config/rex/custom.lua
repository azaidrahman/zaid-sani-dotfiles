-- The Custom group of the Command Palette.
--
-- The Command Palette shows each action with its key. This file
-- changes rex.action, so that each action that this configuration defines
-- goes into the Custom group. The palette search then finds the action by
-- the word "custom" and by its keys. Type "custom" to see only the keys of
-- this configuration.
--
-- Do these steps in init.lua:
--
-- 1. Require this file first.
-- 2. Bind all keys. rex.action reads the keys of an action from the bindings
--    that exist when the action is defined. A key that you bind later is not
--    in the search words.
-- 3. Define or require the actions.
--
-- A function binding has no name, so the palette cannot show it. Bind each
-- key to an action. tests/test-rex-keys.sh checks that each key runs an
-- action of the Custom group.

local CATEGORY = "Custom"

local define = rex.action

-- search_words returns the words that find a key in the palette search. A
-- sequence also gets the name that tmux uses: ctrl+space>shift+x is also
-- prefix+shift+x.
local function search_words(key)
  local prefixed = key:match("^ctrl%+space>(.+)$")
  if prefixed then return key .. " prefix+" .. prefixed end
  return key
end

rex.action = function(spec)
  local words = { "custom" }
  if spec.keywords then table.insert(words, 1, spec.keywords) end
  for _, b in ipairs(rex.bindings{ action = spec.name }) do
    words[#words + 1] = search_words(b.key)
  end
  spec.category = CATEGORY
  spec.keywords = table.concat(words, " ")
  return define(spec)
end
