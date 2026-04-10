-- lib/unified/rehype_accessible_emojis/rehype_accessible_emojis_test.lua
if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T      = require("lib.test.assert")
local a11y   = require("lib.unified.rehype_accessible_emojis")
local rehype = require("lib.unified.rehype")

local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end
local function txt(v)
  return { type = "text", value = v }
end

local function run(root)
  local p = rehype():use(a11y)
  return p:stringify(p:run(root))
end

T.describe("rehype_accessible_emojis: span wrapping", function()
  T.it("wraps a known emoji with role=img and aria-label", function()
    local root = {
      type = "root",
      children = {
        el("p", {}, { txt("\xF0\x9F\x98\x8A") }),  -- 😊
      },
    }
    local html = run(root)
    T.ok(html:find('role="img"', 1, true), "role=img present")
    T.ok(html:find('aria-label="smiling face"', 1, true), "aria-label correct")
    T.ok(html:find("<span", 1, true), "span wraps emoji")
  end)

  T.it("preserves surrounding text", function()
    local root = {
      type = "root",
      children = {
        el("p", {}, { txt("Hello \xF0\x9F\x9A\x80 World") }),  -- 🚀
      },
    }
    local html = run(root)
    T.ok(html:find("Hello", 1, true), "prefix text")
    T.ok(html:find("World", 1, true), "suffix text")
    T.ok(html:find('aria-label="rocket"', 1, true), "emoji label")
  end)

  T.it("handles multiple emoji in one text node", function()
    local root = {
      type = "root",
      children = {
        -- 🔥 fire  +  💡 light bulb
        el("p", {}, { txt("\xF0\x9F\x94\xA5\xF0\x9F\x92\xA1") }),
      },
    }
    local html = run(root)
    T.ok(html:find('aria-label="fire"', 1, true), "fire emoji")
    T.ok(html:find('aria-label="light bulb"', 1, true), "light bulb emoji")
    local count = 0
    local pos = 1
    while true do
      local f = html:find("<span", pos, true)
      if not f then break end
      count = count + 1
      pos = f + 1
    end
    T.eq(count, 2, "two spans")
  end)

  T.it("leaves plain text nodes untouched", function()
    local root = {
      type = "root",
      children = { el("p", {}, { txt("no emoji here") }) },
    }
    local html = run(root)
    T.ok(html:find("no emoji here", 1, true), "text preserved")
    T.ok(not html:find("<span", 1, true), "no span")
  end)

  T.it("handles emoji with variation selector (❤️)", function()
    -- ❤️ = U+2764 U+FE0F = \xE2\x9D\xA4 \xEF\xB8\x8F
    local root = {
      type = "root",
      children = { el("p", {}, { txt("\xE2\x9D\xA4\xEF\xB8\x8F") }) },
    }
    local html = run(root)
    T.ok(html:find('aria-label="red heart"', 1, true), "red heart label")
  end)

  T.it("handles emoji at start and end of text", function()
    local root = {
      type = "root",
      -- 🎉 text 🎉
      children = { el("p", {}, { txt("\xF0\x9F\x8E\x89 text \xF0\x9F\x8E\x89") }) },
    }
    local html = run(root)
    -- Count occurrences with plain search (aria-label contains '-' which is a
    -- Lua pattern operator; use find with plain=true in a loop).
    local count = 0
    local pos = 1
    while true do
      local f = html:find('aria-label="party popper"', pos, true)
      if not f then break end
      count = count + 1
      pos = f + 1
    end
    T.eq(count, 2, "two party popper spans")
  end)

  T.it("recurses into nested elements", function()
    local root = {
      type = "root",
      children = {
        el("div", {}, {
          el("p", {}, { txt("See \xF0\x9F\x91\x8D here") }),  -- 👍
        }),
      },
    }
    local html = run(root)
    T.ok(html:find('aria-label="thumbs up"', 1, true), "nested emoji wrapped")
  end)

  T.it("_names table exposes known emoji", function()
    T.ok(a11y._names["\xF0\x9F\x9A\x80"] == "rocket", "rocket in table")
    T.ok(a11y._names["\xF0\x9F\x92\xBB"] == "laptop", "laptop in table")
  end)
end)
