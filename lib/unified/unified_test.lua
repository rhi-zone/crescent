-- lib/unified/unified_test.lua
local T = require("lib.test.assert")
local unified = require("lib.unified")

-- Minimal helpers used across tests.
--: (source: string) -> { type: string, children: string[] }
local function words_parser(source)
  local words = {}
  for w in source:gmatch("%S+") do words[#words + 1] = w end
  return { type = "words", children = words }
end

--: (ast: { children: Arr<string> }) -> string
local function words_compiler(ast)
  return table.concat(ast.children, " ")
end

T.describe("unified: basic pipeline", function()
  T.it("parse + run + stringify produce expected output", function()
    local p = unified.new()
    p:parser(words_parser)
    p:compiler(words_compiler)

    local ast = p:parse("hello world")
    T.eq(ast.type, "words")
    T.eq(#ast.children, 2)

    local out, err = p:stringify(ast)
    T.eq(err, nil)
    T.eq(out, "hello world")
  end)

  T.it("process() is parse+run+stringify", function()
    local p = unified.new()
    p:parser(words_parser)
    p:compiler(words_compiler)

    local out, err = p:process("foo bar baz")
    T.eq(err, nil)
    T.eq(out, "foo bar baz")
  end)
end)

T.describe("unified: transformers", function()
  T.it("single transformer is applied", function()
    local p = unified.new()
    p:parser(words_parser)
    p:compiler(words_compiler)
    p:use_transformer(function(ast)
      local upper = {}
      for i, w in ipairs(ast.children) do upper[i] = w:upper() end
      return { type = ast.type, children = upper }
    end)

    local out = p:process("hello world")
    T.eq(out, "HELLO WORLD")
  end)

  T.it("multiple transformers run in registration order", function()
    local order = {} --[[: integer[] ]]
    local p = unified.new()
    p:parser(words_parser)
    p:compiler(words_compiler)
    p:use_transformer(function(ast) order[#order + 1] = 1 ; return ast end)
    p:use_transformer(function(ast) order[#order + 1] = 2 ; return ast end)
    p:use_transformer(function(ast) order[#order + 1] = 3 ; return ast end)

    p:run(words_parser("x"))
    T.eq(order[1], 1)
    T.eq(order[2], 2)
    T.eq(order[3], 3)
  end)
end)

T.describe("unified: :use with opts", function()
  T.it("plugin receives processor and opts", function()
    local received_opts
    local function my_plugin(proc, opts)
      received_opts = opts
      proc:use_transformer(function(ast) return ast end)
    end

    local p = unified.new()
    p:parser(words_parser)
    p:compiler(words_compiler)
    p:use(my_plugin, { setting = 42 })

    T.eq(received_opts.setting, 42)
    local out = p:process("test")
    T.eq(out, "test")
  end)

  T.it("plugin can register parser and compiler", function()
    local function full_plugin(proc_, opts)
      local proc = proc_ --[[: any]]
      proc:parser(function(src) return { type = "raw", value = src .. (opts.suffix or "") } end)
      proc:compiler(function(ast) return ast.value end)
    end

    local p = unified.new()
    p:use(full_plugin, { suffix = "!" })

    local out = p:process("hi")
    T.eq(out, "hi!")
  end)
end)

T.describe("unified: :freeze and :clone", function()
  T.it(":freeze prevents direct :use and returns a clone", function()
    local p = unified.new()
    p:parser(words_parser)
    p:compiler(words_compiler)
    p:freeze()

    -- :use on a frozen processor returns a NEW processor (clone), not p
    local p2 = p:use(function(proc) proc:use_transformer(function(ast) return ast end) end)
    T.neq(p2, p)
  end)

  T.it("clone produces independent processor — transformers do not bleed back", function()
    local p = unified.new()
    p:parser(words_parser)
    p:compiler(words_compiler)
    p:freeze()

    local tag = {}
    local p2 = p:clone() --[[: any]]
    p2:use_transformer(function(ast)
      tag[#tag + 1] = "p2"
      return ast
    end)

    -- Run on p2 — tag should contain "p2"
    p2:run(words_parser("x"))
    T.eq(#tag, 1)
    T.eq(tag[1], "p2")

    -- Run on original p (no extra transformers) — tag must not grow
    local before = #tag
    p:run(words_parser("x"))
    T.eq(#tag, before)
  end)

  T.it(":use on frozen returns new processor with plugin applied", function()
    local applied = {}
    local function marker(proc, opts)
      proc:use_transformer(function(ast)
        applied[#applied + 1] = opts.name
        return ast
      end)
    end

    local base = unified.new()
    base:parser(words_parser)
    base:compiler(words_compiler)
    base:use(marker, { name = "base" })
    base:freeze()

    -- :use on frozen returns a clone with both plugins
    local extended = base:use(marker, { name = "ext" })
    applied = {}
    extended:run(words_parser("x"))
    T.eq(applied[1], "base")
    T.eq(applied[2], "ext")
  end)
end)

T.describe("unified: error paths", function()
  T.it("parse returns (nil, errmsg) when no parser registered", function()
    local p = unified.new()
    local result, err = p:parse("x")
    T.eq(result, nil)
    T.ok(err ~= nil, "expected error message")
  end)

  T.it("stringify returns (nil, errmsg) when no compiler registered", function()
    local p = unified.new()
    local result, err = p:stringify({ type = "words", children = {} })
    T.eq(result, nil)
    T.ok(err ~= nil, "expected error message")
  end)
end)
