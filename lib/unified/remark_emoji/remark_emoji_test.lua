-- lib/unified/remark_emoji/remark_emoji_test.lua
-- Tests for the remark_emoji plugin.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local remark = require("lib.unified.remark")
local emoji  = require("lib.unified.remark_emoji")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_proc(opts)
  return remark():use(emoji, opts)
end

local function process(src, opts)
  local proc = make_proc(opts)
  local ast, err = proc:parse(src)
  assert(ast, err)
  ast = proc:run(ast)
  return ast
end

-- Return the value of the first text node in the first paragraph.
local function first_text(ast)
  local para = ast.children[1]
  if not para then return nil end
  -- paragraph may have one or more inline children; find first text node
  local children = para.children or {}
  for i = 1, #children do
    if children[i].type == "text" then
      return children[i].value
    end
  end
  return nil
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("remark_emoji: shortcode replacement", function()
  T.it(":smile: is replaced with the smile emoji", function()
    local ast = process("Hello :smile: world!")
    local v = first_text(ast)
    -- The text node value should contain the 😊 UTF-8 sequence and no raw shortcode.
    T.ok(v ~= nil, "text node exists")
    T.ok(not v:find(":smile:", 1, true), "raw shortcode removed")
    T.ok(v:find("\xF0\x9F\x98\x8A", 1, true), "smile emoji present")
  end)

  T.it(":heart: is replaced with heart emoji", function()
    local ast = process("I :heart: Lua")
    local v = first_text(ast)
    T.ok(v:find("\xE2\x9D\xA4", 1, true), "heart emoji present")
  end)

  T.it(":thumbsup: and +:1: alias both replaced", function()
    local ast = process(":thumbsup: :+1:")
    local v = first_text(ast)
    -- Both map to the same 👍 sequence; appear twice.
    local _, n = v:gsub("\xF0\x9F\x91\x8D", "")
    T.eq(n, 2)
  end)

  T.it("unknown :foo: shortcode is left as-is", function()
    local ast = process("Hello :foo: world")
    local v = first_text(ast)
    T.ok(v:find(":foo:", 1, true), "unknown shortcode preserved")
  end)

  T.it("text without emoji is unchanged", function()
    local ast = process("Just plain text here.")
    local v = first_text(ast)
    T.eq(v, "Just plain text here.")
  end)

  T.it("multiple shortcodes in one text node", function()
    local ast = process(":rocket: :tada: :fire:")
    local v = first_text(ast)
    T.ok(v:find("\xF0\x9F\x9A\x80", 1, true), "rocket present")
    T.ok(v:find("\xF0\x9F\x8E\x89", 1, true), "tada present")
    T.ok(v:find("\xF0\x9F\x94\xA5", 1, true), "fire present")
  end)
end)

T.describe("remark_emoji: custom alias", function()
  T.it("opts.alias adds a new shortcode", function()
    local ast = process(":hello:", { alias = { hello = "\xF0\x9F\x91\x8B" } })
    local v = first_text(ast)
    T.ok(v:find("\xF0\x9F\x91\x8B", 1, true), "custom alias emoji present")
    T.ok(not v:find(":hello:", 1, true), "raw shortcode removed")
  end)

  T.it("opts.alias does not override built-in table", function()
    -- :smile: still works even when alias is provided.
    local ast = process(":smile:", { alias = { custom = "\xF0\x9F\x91\x8B" } })
    local v = first_text(ast)
    T.ok(v:find("\xF0\x9F\x98\x8A", 1, true), "built-in still works")
  end)
end)

T.describe("remark_emoji: emoticon mode", function()
  T.it(":-) is replaced when opts.emoticon = true", function()
    local ast = process("Hello :-) there", { emoticon = true })
    local v = first_text(ast)
    T.ok(not v:find(":%-)", 1, true), "ASCII emoticon removed")
    T.ok(v:find("\xF0\x9F\x98\x8A", 1, true), "smile emoji present")
  end)

  T.it(":-) is NOT replaced when opts.emoticon = false (default)", function()
    local ast = process("Hello :-) there")
    local v = first_text(ast)
    T.ok(v:find(":-)", 1, true), "ASCII emoticon preserved by default")
  end)
end)
