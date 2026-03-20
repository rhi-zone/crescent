if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local pp = require("lib.pretty_print")

T.describe("pretty_print", function()
  T.it("pretty_prints a simple table", function()
    T.eq(pp.uneval({"a", "b", "c"}), '{ "a", "b", "c" }')
  end)

  T.it("pretty_prints a nested table", function()
    T.eq(pp.uneval({1, {2, 3}}), "{ 1, { 2, 3 } }")
  end)

  T.it("pretty_prints an empty table", function()
    T.eq(pp.uneval({}), "{}")
  end)

  T.it("pretty_prints a hash table", function()
    T.eq(pp.uneval({x = 1}), "{ x = 1 }")
  end)
end)

T.describe("uneval", function()
  T.it("unevals a string", function()
    T.eq(pp.uneval("hello"), '"hello"')
  end)

  T.it("unevals a string with escapes", function()
    T.eq(pp.uneval("a\nb"), '"a\\nb"')
  end)

  T.it("unevals an integer", function()
    T.eq(pp.uneval(42), "42")
  end)

  T.it("unevals a float", function()
    T.eq(pp.uneval(3.14), "3.14")
  end)

  T.it("unevals a boolean", function()
    T.eq(pp.uneval(true), "true")
    T.eq(pp.uneval(false), "false")
  end)

  T.it("unevals a table", function()
    T.eq(pp.uneval({1, 2, 3}), "{ 1, 2, 3 }")
  end)
end)
