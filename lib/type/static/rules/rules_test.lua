-- lib/type/static/rules/rules_test.lua
-- Tests for the rule pass infrastructure and Phase 2 AST passes.

local T = require("lib.test.assert")
local check_mod  = require("lib.type.static.check")
local errors_mod = require("lib.type.static.errors")
local rules_mod  = require("lib.type.static.rules")

-- Load all passes so they register themselves.
rules_mod.load_all()

-- Helper: check a source string and run all rule passes.
-- Returns err_ctx after running passes.
local function check_and_run(src, filename)
    filename = filename or "test_lib.lua"
    check_mod.clear_cache()
    local err_ctx, ctx = check_mod.check_string(src, filename)
    if ctx then
        rules_mod.run(ctx, err_ctx, filename, nil)
    end
    return err_ctx
end

-- Helper: count warnings matching a substring.
local function count_warnings(err_ctx, substr)
    local n = 0
    for _, w in ipairs(err_ctx.warnings) do
        if w.msg:find(substr, 1, true) then n = n + 1 end
    end
    return n
end

-- Helper: check whether any warning message contains substr.
local function has_warning(err_ctx, substr)
    return count_warnings(err_ctx, substr) > 0
end

-- Helper: check whether no warning message contains substr.
local function no_warning(err_ctx, substr)
    return count_warnings(err_ctx, substr) == 0
end

---------------------------------------------------------------------------
-- Infrastructure
---------------------------------------------------------------------------

T.describe("rules: infrastructure", function()
    T.it("passes() returns a list of registered passes", function()
        local passes = rules_mod.passes()
        T.ok(#passes >= 6, "at least 6 passes registered")
    end)

    T.it("registered pass names include expected passes", function()
        local names = {}
        for _, entry in ipairs(rules_mod.passes()) do
            names[entry.name] = true
        end
        T.ok(names["unannotated"],       "unannotated registered")
        T.ok(names["assert_in_lib"],     "assert_in_lib registered")
        T.ok(names["naming"],            "naming registered")
        T.ok(names["bare_bit"],          "bare_bit registered")
        T.ok(names["predicate_return"],  "predicate_return registered")
        T.ok(names["dead_locals"],       "dead_locals registered")
    end)

    T.it("run() is a no-op when ctx is nil", function()
        local err_ctx = errors_mod.new_ctx()
        rules_mod.run(nil, err_ctx, "foo.lua", nil)
        T.eq(#err_ctx.warnings, 0)
        T.eq(#err_ctx.errors, 0)
    end)

    T.it("policy 'off' suppresses a pass", function()
        local src = [[
local M = {}
M.foo = function() end
return M
]]
        local err_ctx = check_and_run(src, "test_lib.lua")
        -- unannotated fires by default
        T.ok(has_warning(err_ctx, "no type annotation"), "fires by default")

        -- Now suppress it.
        check_mod.clear_cache()
        local err_ctx2, ctx2 = check_mod.check_string(src, "test_lib.lua")
        if ctx2 then
            rules_mod.run(ctx2, err_ctx2, "test_lib.lua", { unannotated = "off" })
        end
        T.ok(no_warning(err_ctx2, "no type annotation"), "suppressed with off")
    end)
end)

---------------------------------------------------------------------------
-- unannotated pass
---------------------------------------------------------------------------

T.describe("rules/unannotated: public exports without annotation", function()
    T.it("fires when M.name = value has no preceding annotation", function()
        local src = [[
local M = {}
M.foo = function() end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "no type annotation"), "fires for unannotated M.foo")
        T.ok(has_warning(err_ctx, "`foo`"), "names the export")
    end)

    T.it("does not fire when preceding line has --: annotation", function()
        local src = [[
local M = {}
--: (string) -> string
M.foo = function(x) return x end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "no type annotation"), "no warning when annotated")
    end)

    T.it("does not fire on same-line --: annotation", function()
        local src = [[
local M = {}
M.foo = function(x) return x end --: (string) -> string
return M
]]
        -- Same-line annotation: the annotation is on line N, statement is also on line N.
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "no type annotation"), "no warning for same-line annotation")
    end)

    T.it("skips test files", function()
        local src = [[
local M = {}
M.foo = function() end
return M
]]
        local err_ctx = check_and_run(src, "mylib_test.lua")
        T.ok(no_warning(err_ctx, "no type annotation"), "skipped for test file")
    end)

    T.it("does not fire for non-M assignments", function()
        local src = [[
local M = {}
local t = {}
t.foo = function() end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "`foo` has no type annotation"), "only checks M.x")
    end)
end)

---------------------------------------------------------------------------
-- assert_in_lib pass
---------------------------------------------------------------------------

T.describe("rules/assert_in_lib: assert() in library code", function()
    T.it("fires for assert() call at top level", function()
        local src = [[
local M = {}
assert(M ~= nil)
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "assert()` forbidden"), "fires for top-level assert()")
    end)

    T.it("fires for assert() inside a function body", function()
        local src = [[
local M = {}
--: (string) -> string
M.foo = function(x)
    assert(x ~= nil)
    return x
end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "assert()` forbidden"), "fires inside function body")
    end)

    T.it("skips test files", function()
        local src = [[
local M = {}
assert(M ~= nil)
return M
]]
        local err_ctx = check_and_run(src, "mylib_test.lua")
        T.ok(no_warning(err_ctx, "assert()` forbidden"), "skipped for test file")
    end)

    T.it("does not fire when assert is not called", function()
        local src = [[
local M = {}
--: () -> ()
M.foo = function()
    if true then return end
end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "assert()` forbidden"), "no false positive")
    end)

    T.it("fires for assert() inside nested if/while/for", function()
        local src = [[
local M = {}
--: () -> ()
M.foo = function()
    for i = 1, 10 do
        assert(i > 0)
    end
end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "assert()` forbidden"), "fires inside nested for loop")
    end)
end)

---------------------------------------------------------------------------
-- naming pass
---------------------------------------------------------------------------

T.describe("rules/naming: naming conventions", function()
    T.it("fires when no `local M = {}` is present", function()
        local src = [[
local Mod = {}
return Mod
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "module variable not named"), "fires when M missing")
    end)

    T.it("does not fire when `local M = {}` is present", function()
        local src = [[
local M = {}
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "module variable not named"), "no warning when M present")
    end)

    T.it("fires for M.create assignment", function()
        local src = [[
local M = {}
--: () -> {}
M.create = function() return {} end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "M.create"), "fires for M.create")
        T.ok(has_warning(err_ctx, "M.new"), "suggests M.new")
    end)

    T.it("fires for M.destroy assignment", function()
        local src = [[
local M = {}
--: ({}) -> ()
M.destroy = function(self) end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "M.destroy"), "fires for M.destroy")
    end)

    T.it("fires for function M.free(...) declaration", function()
        local src = [[
local M = {}
function M.free(self) end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "M.free"), "fires for function M.free declaration")
    end)

    T.it("does not fire for M.new", function()
        local src = [[
local M = {}
--: () -> {}
M.new = function() return {} end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "M.new"), "no warning for M.new")
    end)

    T.it("skips test files", function()
        local src = [[
local Mod = {}
Mod.create = function() end
return Mod
]]
        local err_ctx = check_and_run(src, "mylib_test.lua")
        T.ok(no_warning(err_ctx, "module variable not named"), "skipped test file")
        T.ok(no_warning(err_ctx, "M.create"), "skipped test file banned name")
    end)
end)

---------------------------------------------------------------------------
-- bare_bit pass
---------------------------------------------------------------------------

T.describe("rules/bare_bit: bare bit.* global", function()
    T.it("fires when bit.bxor is used without local bit", function()
        local src = [[
local M = {}
--: (integer) -> integer
M.flip = function(x)
    return bit.bxor(x, 0xFF)
end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "bare `bit.*`"), "fires for bare bit.bxor")
    end)

    T.it("does not fire when local bit = require('bit') is present", function()
        local src = [[
local bit = require("bit")
local M = {}
--: (integer) -> integer
M.flip = function(x)
    return bit.bxor(x, 0xFF)
end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "bare `bit.*`"), "no warning with local bit")
    end)

    T.it("does not fire when bit is not used", function()
        local src = [[
local M = {}
--: (string) -> string
M.id = function(x) return x end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "bare `bit.*`"), "no false positive without bit usage")
    end)

    T.it("skips test files", function()
        local src = [[
local M = {}
M.x = bit.band(1, 2)
return M
]]
        local err_ctx = check_and_run(src, "mylib_test.lua")
        T.ok(no_warning(err_ctx, "bare `bit.*`"), "skipped for test file")
    end)

    T.it("does not fire when bit is in a comment only", function()
        local src = [[
-- Uses bit.bxor internally (but not in code)
local M = {}
--: (string) -> string
M.id = function(x) return x end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "bare `bit.*`"), "comment-only bit mention not flagged")
    end)
end)

---------------------------------------------------------------------------
-- predicate_return pass
---------------------------------------------------------------------------

T.describe("rules/predicate_return: is_*/has_* should return boolean", function()
    T.it("fires when M.is_valid returns a number", function()
        local src = [[
local M = {}
--: () -> integer
M.is_valid = function() return 42 end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "is_valid"), "fires for non-boolean return")
        T.ok(has_warning(err_ctx, "is_*`/`has_*` should return boolean"), "message mentions predicate convention")
    end)

    T.it("does not fire when M.is_valid returns boolean", function()
        local src = [[
local M = {}
--: () -> boolean
M.is_valid = function() return true end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "is_valid"), "no warning for boolean return")
    end)

    T.it("fires when M.has_item returns a string", function()
        local src = [[
local M = {}
--: (string) -> string
M.has_item = function(x) return x end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "has_item"), "fires for has_* with non-boolean return")
    end)

    T.it("does not fire when M.has_item returns boolean", function()
        local src = [[
local M = {}
--: (string) -> boolean
M.has_item = function(x) return x ~= nil end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "has_item"), "no warning for boolean return in has_*")
    end)

    T.it("does not fire for names not starting with is_ or has_", function()
        local src = [[
local M = {}
--: () -> integer
M.get_count = function() return 42 end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "get_count"), "non-predicate name not flagged")
    end)

    T.it("skips test files", function()
        local src = [[
local M = {}
M.is_valid = function() return 42 end
return M
]]
        local err_ctx = check_and_run(src, "mylib_test.lua")
        -- Use the predicate_return-specific message substring rather than
        -- just "is_valid", since the missing-signature warning (after HM
        -- demotion in 2026-05-15) also includes the function name.
        T.ok(no_warning(err_ctx, "should return boolean"), "skipped for test file")
    end)
end)

---------------------------------------------------------------------------
-- dead_locals pass
---------------------------------------------------------------------------

T.describe("rules/dead_locals: assigned but never read", function()
    T.it("fires when a local variable is never read", function()
        local src = [[
local M = {}
local x = 1
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(has_warning(err_ctx, "local `x` is assigned but never read"), "fires for unused local")
    end)

    T.it("does not fire when a local is used in a return", function()
        local src = [[
local M = {}
local x = 1
return x
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "local `x`"), "no warning when x is returned")
    end)

    T.it("does not fire when a local is used in an expression", function()
        local src = [[
local M = {}
local x = 10
--: () -> integer
M.get = function() return x end
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "local `x`"), "no warning when x is captured in closure")
    end)

    T.it("does not fire for underscore-prefixed names", function()
        local src = [[
local M = {}
local _unused = 1
return M
]]
        local err_ctx = check_and_run(src, "mylib.lua")
        T.ok(no_warning(err_ctx, "_unused"), "underscore-prefixed locals are ignored")
    end)

    T.it("skips test files", function()
        local src = [[
local M = {}
local x = 1
return M
]]
        local err_ctx = check_and_run(src, "mylib_test.lua")
        T.ok(no_warning(err_ctx, "local `x`"), "skipped for test file")
    end)
end)
