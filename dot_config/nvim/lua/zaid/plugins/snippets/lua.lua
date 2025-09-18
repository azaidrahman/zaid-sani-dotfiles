local luasnip = require("luasnip")
local s = luasnip.snippet
local i = luasnip.insert_node
local fmt = require("luasnip.extras.fmt").fmt

return {
  s(
    "req",
    fmt([[local {} = require("{}")]], {
      i(1, "module"),
      i(2, "module_name"),
    })
  ),
}


