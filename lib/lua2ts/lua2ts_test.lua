-- lib/lua2ts/lua2ts_test.lua
-- Tests for the Lua → TypeScript transpiler.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local lua2ts = require("lib.lua2ts")

-- Helper: transpile and assert output contains a substring.
local function has(lua_src, expected, desc)
    local ts, err = lua2ts.transpile(lua_src, { filename = "test.lua" })
    T.ok(ts ~= nil, desc .. " (no error: " .. tostring(err) .. ")")
    if ts then
        T.ok(ts:find(expected, 1, true) ~= nil,
            desc .. ": expected " .. string.format("%q", expected) .. " in:\n" .. ts)
    end
end

-- Helper: transpile and assert output does NOT contain a substring.
local function hasnt(lua_src, unexpected, desc)
    local ts, err = lua2ts.transpile(lua_src, { filename = "test.lua" })
    T.ok(ts ~= nil, desc .. " (no error)")
    if ts then
        T.ok(ts:find(unexpected, 1, true) == nil,
            desc .. ": did not expect " .. string.format("%q", unexpected))
    end
end

-- ---------------------------------------------------------------------------
-- Basic literals and declarations
-- ---------------------------------------------------------------------------

T.describe("local declaration with initializer", function()
    has("local x = 1 + 2", "const x = 1 + 2", "const assignment")
    has("local x = 1 + 2", "1 + 2", "arithmetic preserved")
end)

T.describe("local declaration without initializer", function()
    has("local x", "let x", "bare local → let")
    hasnt("local x", "const", "no const for uninit")
end)

T.describe("string literals", function()
    has([[local s = "hello"]], '"hello"', "string literal")
end)

T.describe("boolean literals", function()
    has("local t = true", "true", "true literal")
    has("local f = false", "false", "false literal")
end)

T.describe("nil literal", function()
    has("local n = nil", "null", "nil → null")
end)

-- ---------------------------------------------------------------------------
-- Operators
-- ---------------------------------------------------------------------------

T.describe("equality operators", function()
    has("local r = x == y", "===", "== → ===")
    has("local r = x ~= y", "!==", "~= → !==")
end)

T.describe("power operator", function()
    has("local r = x ^ y", "**", "^ → **")
end)

T.describe("logical operators", function()
    has("local r = x and y", "&&", "and → &&")
    has("local r = x or y", "||", "or → ||")
    has("local r = not x", "!", "not → !")
end)

T.describe("length operator", function()
    has("local n = #arr", ".length", "#arr → .length")
end)

T.describe("concatenation operator", function()
    has([[local s = "a" .. "b"]], '+', ".. → +")
end)

-- ---------------------------------------------------------------------------
-- Method calls
-- ---------------------------------------------------------------------------

T.describe("method call syntax", function()
    has("x:method(y)", "x.method(y)", "colon method → dot method")
    has("foo:bar(1, 2)", "foo.bar(1, 2)", "method with args")
end)

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

T.describe("local function declaration", function()
    has("local function f(a, b) return a + b end", "function f", "local function")
    has("local function f(a, b) return a + b end", "return a + b", "function body")
end)

T.describe("function expression / arrow function", function()
    has("local f = function(a, b) return a end", "=>", "arrow function")
end)

T.describe("vararg function", function()
    has("local function f(...) end", "...args", "vararg → ...args")
end)

-- ---------------------------------------------------------------------------
-- Error handling
-- ---------------------------------------------------------------------------

T.describe("error() becomes throw", function()
    has([[error("msg")]], "throw", "error → throw")
    has([[error("msg")]], "new Error", "error → new Error")
end)

-- ---------------------------------------------------------------------------
-- For loops
-- ---------------------------------------------------------------------------

T.describe("numeric for loop (0-indexed)", function()
    has("for i = 1, 10 do end", "for (let i = ", "numeric for loop")
    has("for i = 1, 10 do end", "i = 0", "1-indexed → 0-indexed")
    has("for i = 1, 10 do end", "i <= 10", "limit preserved")
end)

T.describe("numeric for with step", function()
    has("for i = 1, 10, 2 do end", "i += 2", "step preserved")
end)

T.describe("generic for with ipairs", function()
    has("for i, v in ipairs(t) do end", ".entries()", "ipairs → .entries()")
end)

T.describe("generic for with pairs", function()
    has("for k, v in pairs(t) do end", "Object.entries(", "pairs → Object.entries")
end)

-- ---------------------------------------------------------------------------
-- Table constructors
-- ---------------------------------------------------------------------------

T.describe("array table", function()
    has("local t = {1, 2, 3}", "[1, 2, 3]", "array table → JS array")
end)

T.describe("object table", function()
    has("local t = {x = 1, y = 2}", "x: 1", "object table key")
    has("local t = {x = 1, y = 2}", "y: 2", "object table value")
end)

T.describe("empty table", function()
    has("local t = {}", "{}", "empty table → {}")
end)

-- ---------------------------------------------------------------------------
-- Require / import
-- ---------------------------------------------------------------------------

T.describe("require becomes ESM import", function()
    has([[local foo = require("lib.foo")]], "import * as foo", "require → import")
    has([[local foo = require("lib.foo")]], 'from "./lib/foo"', "import path")
    -- The local declaration line should NOT be emitted
    hasnt([[local foo = require("lib.foo")]], "const foo", "no const for require")
end)

T.describe("cjs mode keeps require", function()
    local ts = lua2ts.transpile([[local foo = require("lib.foo")]], { module = "cjs" })
    T.ok(ts ~= nil, "cjs mode transpiles")
    if ts then
        T.ok(ts:find("require", 1, true) ~= nil, "cjs: require kept")
    end
end)

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

T.describe("annotated function emits return type", function()
    -- --: (integer, integer) -> integer
    -- local function add(a, b) return a + b end
    local src = "--: (integer, integer) -> integer\nlocal function add(a, b) return a + b end"
    local ts, err = lua2ts.transpile(src)
    T.ok(ts ~= nil, "annotated fn transpiles: " .. tostring(err))
    if ts then
        -- Should contain "number" (integer → number) and "=>" somewhere
        T.ok(ts:find("number", 1, true) ~= nil, "annotation: integer → number")
    end
end)

-- ---------------------------------------------------------------------------
-- Control flow
-- ---------------------------------------------------------------------------

T.describe("if statement", function()
    has("if x then y() end", "if (x)", "if condition")
    has("if x then y() end", "{", "if brace")
end)

T.describe("if-else statement", function()
    has("if x then y() else z() end", "else {", "else branch")
end)

T.describe("while loop", function()
    has("while x do y() end", "while (x) {", "while loop")
end)

T.describe("repeat-until loop", function()
    has("repeat y() until x", "do {", "repeat → do")
    has("repeat y() until x", "while (!(x))", "until → while(not)")
end)

-- ---------------------------------------------------------------------------
-- Multiple assignments / returns
-- ---------------------------------------------------------------------------

T.describe("multiple return values", function()
    has("return a, b, c", "return [a, b, c]", "multiple returns → array")
end)

T.describe("multiple assignment", function()
    has("a, b = b, a", "[a, b] = [b, a]", "swap assignment")
end)

-- ---------------------------------------------------------------------------
-- x.new() → new x()
-- ---------------------------------------------------------------------------

T.describe("x.new() → new x()", function()
    has("local obj = Foo.new(1, 2)", "new Foo(1, 2)", "x.new → new x")
end)

-- ---------------------------------------------------------------------------
-- pcall → try/catch
-- ---------------------------------------------------------------------------

T.describe("pcall becomes try/catch IIFE", function()
    has("local ok, err = pcall(f, x)", "try {", "pcall → try")
    has("local ok, err = pcall(f, x)", "[true,", "pcall success path")
    has("local ok, err = pcall(f, x)", "[false,", "pcall failure path")
end)

-- ---------------------------------------------------------------------------
-- Strict mode header
-- ---------------------------------------------------------------------------

T.describe("strict mode header", function()
    local ts = lua2ts.transpile("local x = 1", { strict = true })
    T.ok(ts ~= nil, "strict mode transpiles")
    if ts then
        T.ok(ts:find("@ts-strict-mode", 1, true) ~= nil, "strict header present")
    end
end)

-- ---------------------------------------------------------------------------
-- transpile_file
-- ---------------------------------------------------------------------------

T.describe("transpile_file error on missing file", function()
    local ts, err = lua2ts.transpile_file("/nonexistent/path.lua")
    T.ok(ts == nil, "nil on missing file")
    T.ok(err ~= nil, "error message on missing file")
end)

-- ---------------------------------------------------------------------------
-- Field access
-- ---------------------------------------------------------------------------

T.describe("field access", function()
    has("local x = foo.bar", "foo.bar", "field access")
    has("local x = a.b.c", "a.b.c", "chained field access")
end)

-- ---------------------------------------------------------------------------
-- Index access
-- ---------------------------------------------------------------------------

T.describe("index access", function()
    has("local x = t[k]", "t[k]", "index access")
end)

-- ---------------------------------------------------------------------------
-- OOP class pattern: __index = table metatable
-- ---------------------------------------------------------------------------

local oop_basic = [[
local M = {}
M.__index = M

function M.new(x, y)
  local self = setmetatable({}, M)
  self.x = x
  self.y = y
  return self
end

function M:greet()
  return "hi " .. self.x
end

function M.version()
  return 1
end
]]

T.describe("OOP: class keyword emitted", function()
    has(oop_basic, "class M {", "class declaration")
    hasnt(oop_basic, "local M = {}", "no local table decl")
    hasnt(oop_basic, "M.__index = M", "no __index assignment")
end)

T.describe("OOP: constructor emitted", function()
    has(oop_basic, "constructor(x, y)", "constructor signature")
    has(oop_basic, "const self = this;", "self = this preamble in ctor")
    -- setmetatable call must be removed
    hasnt(oop_basic, "setmetatable", "no setmetatable call")
    -- return self must be removed from constructor
    hasnt(oop_basic, "return self", "no return self in ctor")
end)

T.describe("OOP: instance method emitted", function()
    has(oop_basic, "greet()", "instance method signature (no self param)")
    has(oop_basic, "const self = this;", "self = this preamble in method")
end)

T.describe("OOP: static method emitted", function()
    has(oop_basic, "static version()", "static method")
end)

T.describe("OOP: setmetatable with {__index=M} variant", function()
    local src = [[
local A = {}
A.__index = A

function A.new(v)
  local self = setmetatable({}, { __index = A })
  self.v = v
  return self
end

function A:get()
  return self.v
end
]]
    has(src, "class A {", "class from {__index=M}")
    hasnt(src, "setmetatable", "no setmetatable")
    has(src, "constructor(v)", "constructor")
    has(src, "get()", "instance method")
end)

T.describe("OOP: explicit self parameter", function()
    local src = [[
local Vec = {}
Vec.__index = Vec

function Vec.new(x, y)
  local self = setmetatable({}, Vec)
  self.x = x
  self.y = y
  return self
end

function Vec.dot(self, other)
  return self.x * other.x + self.y * other.y
end
]]
    has(src, "class Vec {", "class emitted")
    has(src, "dot(other)", "explicit self stripped from params")
    hasnt(src, "dot(self,", "no self in emitted params")
end)

T.describe("OOP: plain table without __index stays unchanged", function()
    local src = [[
local t = {}
t.x = 1
]]
    has(src, "const t = {}", "plain table is const, not class")
    hasnt(src, "class t", "no class for plain table")
end)

T.describe("OOP: M.new() → new M() still works after class synthesis", function()
    -- When calling the constructor from outside the class definition, x.new(...)
    -- is already translated to new x(...) by the existing rule.
    has("local obj = M.new(1, 2)", "new M(1, 2)", "x.new → new x still works")
end)
