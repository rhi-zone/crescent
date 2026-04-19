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

-- ---------------------------------------------------------------------------
-- __index = OtherTable delegation → Object.setPrototypeOf
-- ---------------------------------------------------------------------------

T.describe("__index = Base delegation emits Object.setPrototypeOf", function()
    local src = [[
local M = {}
M.__index = Base
]]
    has(src, "Object.setPrototypeOf(M, Base)", "delegation emits setPrototypeOf")
    hasnt(src, "M.__index = Base", "raw __index assignment not emitted")
end)

T.describe("__index = require(...) delegation emits Object.setPrototypeOf", function()
    local src = [[
local M = {}
M.__index = require("lib.foo")
]]
    has(src, "Object.setPrototypeOf(M,", "require delegation emits setPrototypeOf")
    hasnt(src, "M.__index", "raw __index not emitted")
end)

T.describe("__index = M self-referential is NOT treated as delegation", function()
    -- The class pattern absorbs M.__index = M; no setPrototypeOf should appear.
    local src = [[
local M = {}
M.__index = M

function M.new()
  local self = setmetatable({}, M)
  return self
end
]]
    hasnt(src, "Object.setPrototypeOf", "no setPrototypeOf for self-referential __index")
    has(src, "class M {", "class emitted for self-referential pattern")
end)

-- ---------------------------------------------------------------------------
-- Bundle API
-- ---------------------------------------------------------------------------

-- Helper: call M.bundle and assert output contains a substring.
local function bundle_has(entry_path, entry_src, resolve_fn, expected, desc, opts)
    local out, err = lua2ts.bundle(entry_path, entry_src, resolve_fn, opts)
    T.ok(out ~= nil, desc .. " (no error: " .. tostring(err) .. ")")
    if out then
        T.ok(out:find(expected, 1, true) ~= nil,
            desc .. ": expected " .. string.format("%q", expected) .. " in:\n" .. out)
    end
end

local function bundle_hasnt(entry_path, entry_src, resolve_fn, unexpected, desc, opts)
    local out, err = lua2ts.bundle(entry_path, entry_src, resolve_fn, opts)
    T.ok(out ~= nil, desc .. " (no error: " .. tostring(err) .. ")")
    if out then
        T.ok(out:find(unexpected, 1, true) == nil,
            desc .. ": did not expect " .. string.format("%q", unexpected) .. " in:\n" .. out)
    end
end

T.describe("bundle: preamble and registry present", function()
    local out, err = lua2ts.bundle("entry", "local x = 1", function() return nil end)
    T.ok(out ~= nil, "bundle succeeds: " .. tostring(err))
    if out then
        T.ok(out:find("__modules", 1, true) ~= nil, "preamble: __modules present")
        T.ok(out:find("__require", 1, true) ~= nil, "preamble: __require present")
        T.ok(out:find('__require("entry")', 1, true) ~= nil, "entry runner present")
    end
end)

T.describe("bundle: two-file — entry requires one dep", function()
    local dep_src = [[local M = {} ; M.value = 42 ; return M]]
    local entry_src = [[local dep = require("myapp.dep") ; local v = dep.value]]
    local resolve = function(name)
        if name == "myapp.dep" then return dep_src end
        return nil
    end
    -- dep module appears in bundle
    bundle_has("myapp.entry", entry_src, resolve, '__modules["myapp/dep"]', "dep module in bundle")
    -- entry module appears in bundle
    bundle_has("myapp.entry", entry_src, resolve, '__modules["myapp/entry"]', "entry module in bundle")
    -- require rewritten to __require
    bundle_has("myapp.entry", entry_src, resolve, '__require("myapp/dep")', "require rewritten to __require")
    -- no ESM import in bundle output
    bundle_hasnt("myapp.entry", entry_src, resolve, "import * as", "no ESM import in bundle")
end)

T.describe("bundle: dep exports accessible from entry", function()
    local dep_src = [[exports = {} ; exports.greet = function(name) return "hi " .. name end]]
    local entry_src = [[local dep = require("app.greet") ; dep.greet("world")]]
    local resolve = function(name)
        if name == "app.greet" then return dep_src end
        return nil
    end
    -- dep factory wraps its body
    bundle_has("app.main", entry_src, resolve, 'factory: (exports, __require)', "factory signature present")
    -- entry calls __require to get dep
    bundle_has("app.main", entry_src, resolve, '__require("app/greet")', "entry calls __require for dep")
end)

T.describe("bundle: external dep (resolve returns nil) not inlined", function()
    local entry_src = [[local ext = require("platform.fs") ; ext.read("x.txt")]]
    local resolve = function() return nil end  -- all external
    -- entry module still bundled
    bundle_has("app.main", entry_src, resolve, '__modules["app/main"]', "entry still bundled")
    -- __require call still emitted (runtime will look it up)
    bundle_has("app.main", entry_src, resolve, '__require("platform/fs")', "external dep call kept")
    -- no factory for the external module
    bundle_hasnt("app.main", entry_src, resolve, '__modules["platform/fs"]', "external dep not inlined")
end)

T.describe("bundle: cycle — A requires B, B requires A", function()
    local a_src = [[local b = require("app.b") ; local function fa() return b end]]
    local b_src = [[local a = require("app.a") ; local function fb() return a end]]
    local sources = { ["app.a"] = a_src, ["app.b"] = b_src }
    local resolve = function(name) return sources[name] end
    -- Both modules must appear in the bundle
    local out, err = lua2ts.bundle("app.a", a_src, resolve)
    T.ok(out ~= nil, "cycle: bundle succeeds (no error: " .. tostring(err) .. ")")
    if out then
        T.ok(out:find('__modules["app/a"]', 1, true) ~= nil, "cycle: app.a in bundle")
        T.ok(out:find('__modules["app/b"]', 1, true) ~= nil, "cycle: app.b in bundle")
    end
end)

T.describe("bundle: deep transitive — A → B → C, all three bundled", function()
    local c_src = [[local M = {} ; M.val = 3 ; return M]]
    local b_src = [[local c = require("app.c") ; local M = {} ; M.val = c.val + 1 ; return M]]
    local a_src = [[local b = require("app.b") ; local x = b.val]]
    local sources = { ["app.b"] = b_src, ["app.c"] = c_src }
    local resolve = function(name) return sources[name] end
    -- All three modules appear in the output
    bundle_has("app.a", a_src, resolve, '__modules["app/a"]', "deep: app.a bundled")
    bundle_has("app.a", a_src, resolve, '__modules["app/b"]', "deep: app.b bundled")
    bundle_has("app.a", a_src, resolve, '__modules["app/c"]', "deep: app.c bundled")
    -- C appears before B (depth-first topological order)
    local out = lua2ts.bundle("app.a", a_src, resolve)
    if out then
        local pos_c = out:find('__modules["app/c"]', 1, true)
        local pos_b = out:find('__modules["app/b"]', 1, true)
        T.ok(pos_c ~= nil and pos_b ~= nil and pos_c < pos_b,
            "deep: C emitted before B (topological order)")
    end
end)
