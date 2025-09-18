local luasnip = require("luasnip")
local s = luasnip.snippet
local t = luasnip.text_node
local i = luasnip.insert_node
local extras = require("luasnip.extras")
local rep = extras.rep
local fmt = require("luasnip.extras.fmt").fmt

return {
  s(
    "!foo",
    fmt(
      [[
      <script setup lang="ts">{}</script>

      <template>
        <div>
          <h1>{}</h1>
        </div>
      </template>
      ]],
      {
        i(1),
        i(0),
      }
    )
  ),
}
