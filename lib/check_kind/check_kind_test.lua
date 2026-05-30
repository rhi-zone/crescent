-- lib/check_kind/check_kind_test.lua
-- Tests for checker #1, the value/kind checker.
--
-- Each REJECT test asserts at least one diagnostic whose message names the
-- violated expectation. Each ACCEPT test asserts zero diagnostics. This proves
-- soundness on the four core misuse classes and confirms valid code is clean.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local ck = require("lib.check_kind")

local describe, it = T.describe, T.it

-- Helper: run the checker and return the diagnostics list.
local function errs(src)
    return ck.check(src, "test.lua")
end

-- Helper: true if some diagnostic message contains `needle`.
local function has_err(src, needle)
    for _, e in ipairs(errs(src)) do
        if e.msg:find(needle, 1, true) then return true end
    end
    return false
end

-- Helper: count of diagnostics.
local function n_errs(src)
    return #errs(src)
end

---------------------------------------------------------------------------
-- 1. Calling a non-function.
---------------------------------------------------------------------------
describe("call a non-function", function()
    it("REJECTS calling a number", function()
        local src = [[
local x = 5
x()
]]
        T.ok(has_err(src, "call requires a function"),
            "should reject calling a number")
    end)

    it("REJECTS calling a string", function()
        local src = [[
local s = "hi"
s()
]]
        T.ok(has_err(src, "call requires a function"),
            "should reject calling a string")
    end)

    it("ACCEPTS calling an annotated function", function()
        local src = [[
--: (number) -> number
local function f(n) return n end
local y = f(3)
]]
        T.eq(n_errs(src), 0, "valid call should be clean")
    end)
end)

---------------------------------------------------------------------------
-- 2. Indexing a non-table.
---------------------------------------------------------------------------
describe("index a non-table", function()
    it("REJECTS field access on a number", function()
        local src = [[
local n = 3
local y = n.field
]]
        T.ok(has_err(src, "index requires a table"),
            "should reject .field on a number")
    end)

    it("REJECTS bracket index on a string", function()
        local src = [[
local s = "x"
local y = s[1]
]]
        T.ok(has_err(src, "index requires a table"),
            "should reject s[1] on a string")
    end)

    it("ACCEPTS indexing a table constructor", function()
        local src = [[
local t = { a = 1 }
local y = t.a
local z = t[1]
]]
        T.eq(n_errs(src), 0, "valid index should be clean")
    end)
end)

---------------------------------------------------------------------------
-- 3. Arithmetic / concat on the wrong atom.
---------------------------------------------------------------------------
describe("arithmetic on a string", function()
    it("REJECTS adding a string", function()
        local src = [[
local s = "5"
local y = s + 1
]]
        T.ok(has_err(src, "arithmetic requires a number"),
            "should reject string + number")
    end)

    it("REJECTS unary minus on a string", function()
        local src = [[
local s = "5"
local y = -s
]]
        T.ok(has_err(src, "unary minus requires a number"),
            "should reject -string")
    end)

    it("REJECTS concat of a number-typed... still accepts numbers? no: concat requires string", function()
        local src = [[
local t = { }
local y = t .. "x"
]]
        T.ok(has_err(src, "concat `..` requires a string"),
            "should reject table .. string")
    end)

    it("ACCEPTS arithmetic on numbers", function()
        local src = [[
local a = 2
local b = 3
local c = a * b + 1
]]
        T.eq(n_errs(src), 0, "number arithmetic should be clean")
    end)

    it("ACCEPTS concat of strings", function()
        local src = [[
local a = "x"
local b = "y"
local c = a .. b
]]
        T.eq(n_errs(src), 0, "string concat should be clean")
    end)
end)

---------------------------------------------------------------------------
-- 4. A possibly-nil value used where non-nil is required.
---------------------------------------------------------------------------
describe("possibly-nil value where non-nil is required", function()
    it("REJECTS arithmetic on a `number | nil`", function()
        local src = [[
--: number | nil
local x = nil
local y = x + 1
]]
        T.ok(has_err(src, "may be nil"),
            "should reject arithmetic on a nilable number")
    end)

    it("REJECTS calling a `function | nil`", function()
        local src = [[
--: (() -> number) | nil
local f = nil
local y = f()
]]
        T.ok(has_err(src, "may be nil"),
            "should reject calling a nilable function")
    end)

    it("ACCEPTS use after an `if` narrows away nil", function()
        local src = [[
--: number | nil
local x = nil
if x then
  local y = x + 1
end
]]
        T.eq(n_errs(src), 0, "narrowed value should be usable")
    end)

    it("ACCEPTS use of a non-nil annotated number", function()
        local src = [[
--: number
local x = 1
local y = x + 1
]]
        T.eq(n_errs(src), 0, "non-nil number should be usable")
    end)
end)

---------------------------------------------------------------------------
-- 5. Wrong argument kind to an annotated function.
---------------------------------------------------------------------------
describe("wrong argument kind", function()
    it("REJECTS passing a string where number is required", function()
        local src = [[
--: (number) -> number
local function f(n) return n end
local y = f("oops")
]]
        T.ok(has_err(src, "argument #1 expects `number`"),
            "should reject string argument to (number) -> number")
    end)

    it("ACCEPTS the correct argument kind", function()
        local src = [[
--: (number) -> number
local function f(n) return n end
local y = f(42)
]]
        T.eq(n_errs(src), 0, "correct argument should be clean")
    end)
end)

---------------------------------------------------------------------------
-- 6. Return mismatch against a declared arrow.
---------------------------------------------------------------------------
describe("return mismatch", function()
    it("REJECTS returning a string from a (number) -> number", function()
        local src = [[
--: (number) -> number
local function f(n)
  return "nope"
end
]]
        T.ok(has_err(src, "return expects `number`"),
            "should reject string return where number is declared")
    end)

    it("ACCEPTS a matching return", function()
        local src = [[
--: (number) -> number
local function f(n)
  return n
end
]]
        T.eq(n_errs(src), 0, "matching return should be clean")
    end)
end)

---------------------------------------------------------------------------
-- 7. Termination / robustness: clean program produces no errors and does not
--    hang (the harness would time out otherwise).
---------------------------------------------------------------------------
describe("robustness", function()
    it("handles a larger clean program with no diagnostics", function()
        local src = [[
--: (number, number) -> number
local function add(a, b)
  return a + b
end

local t = { count = 0 }
for i = 1, 10 do
  t.count = i
end

local s = "a" .. "b"
local total = add(1, 2)
]]
        T.eq(n_errs(src), 0, "clean program should produce no diagnostics")
    end)
end)
