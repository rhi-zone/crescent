-- lib/type/v9/lower_test.lua
-- The total lowering over REAL Lua syntax: the and/or derivation (regression
-- for the historic hardcoded `foo and bar -> boolean|nil` bug), truthiness
-- narrowing with join-at-merge, the honest unsupported boundary with
-- line/col, the havoc fence, and the 30-kind totality roster.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local frontend = require("lib.type.v9.frontend")
local lower = require("lib.type.v9.lower")
local engine = require("lib.type.v9.engine.engine")
local lattice = require("lib.type.v9.lattice")

-- Lower + solve a snippet; return rendered types of top-level locals plus
-- the lowering diags. Fails the test on parse/solve errors.
--: (string) -> ({ [string]: string }, { [integer]: { code: string, severity: string, message: string, line: integer, col: integer } })
local function infer(src)
    local ast, perr = frontend.parse(src, "test.lua")
    if ast == nil then error("parse failed: " .. (perr or "?")) end
    local res = lower.lower(ast)
    local sol, serr = engine.solve(res.graph)
    if sol == nil then error("solve failed: " .. (serr or "?")) end
    local out = {} --: { [string]: string }
    for name, cell in pairs(res.vars) do
        out[name] = lattice.show(sol.values[cell])
    end
    return out, res.diags
end

--: ({ [integer]: { code: string, severity: string, message: string, line: integer, col: integer } }, string) -> { code: string, severity: string, message: string, line: integer, col: integer } | nil
local function find_diag(diags, code)
    for i = 1, #diags do
        if diags[i].code == code then return diags[i] end
    end
    return nil
end

T.describe("v9 lowering — and/or DERIVED from truthy/falsy (the historic bug site)", function()
    T.it("foo and bar : type(bar) when foo is never-falsy (NOT boolean|nil)", function()
        local tys = infer("local foo = 1\nlocal bar = 'b'\nlocal x = foo and bar\nreturn x\n")
        T.eq(tys.x, "string", "number is never falsy, so `foo and bar` is exactly bar's type")
    end)

    T.it("a and b : falsy(a) | type(b) when a is optional", function()
        local tys = infer("local a = nil\nlocal x = a and 1\nreturn x\n")
        T.eq(tys.x, "nil | number", "falsy(nil) | number")
    end)

    T.it("a or b : truthy(a) | type(b) (default-value idiom)", function()
        local tys = infer("local a = nil\nlocal x = a or 'd'\nreturn x\n")
        T.eq(tys.x, "string", "truthy(nil) = never, so the default's type wins")
    end)

    T.it("a or b keeps a's truthy part when a can be truthy", function()
        local tys = infer("local a = 1\nlocal x = a or 'd'\nreturn x\n")
        T.eq(tys.x, "number | string", "truthy(number) | string")
    end)

    T.it("cond and a or b : type(a) | type(b) when a is never falsy (the classic idiom)", function()
        -- pre-split this leaked `boolean | number` (falsy(boolean) was the
        -- whole boolean atom); with literal atoms falsy(boolean) = false and
        -- truthy(false | number) = number.
        local tys = infer("local c = 1 == 2\nlocal x = c and 1 or 2\nreturn x\n")
        T.eq(tys.x, "number", "no phantom boolean leaks out of the ternary idiom")
    end)

    T.it("boolean literals are the true/false literal atoms", function()
        local tys = infer("local t = true\nlocal f = false\nlocal b = 1 == 1\nreturn t, f, b\n")
        T.eq(tys.t, "true", "the literal atom, not the boolean top")
        T.eq(tys.f, "false", "same for false")
        T.eq(tys.b, "boolean", "a comparison is the full pair (renders collapsed)")
    end)
end)

T.describe("v9 lowering — nil-equality guards (the == nil / ~= nil idiom)", function()
    T.it("`if x ~= nil then` narrows x in the then-arm; `== nil` swaps", function()
        local src = "local c = true\nlocal x = nil\nif c then x = 1 end\n"
            .. "local y = 0\nif x ~= nil then y = x end\n"
            .. "local z = nil\nif x == nil then z = x end\nreturn y, z\n"
        local tys = infer(src)
        T.eq(tys.y, "number", "x ~= nil drops nil in the then-arm")
        T.eq(tys.z, "nil", "x == nil keeps only nil in the then-arm")
    end)

    T.it("either operand order works (nil == x)", function()
        local src = "local c = true\nlocal x = nil\nif c then x = 's' end\n"
            .. "local y = 0\nif nil ~= x then y = x end\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "number | string", "swapped operands narrow the same way")
    end)
end)

T.describe("v9 lowering — truthiness narrowing + join at merge", function()
    T.it("branch versions join to a union at the if-merge", function()
        local tys = infer("local x = 1\nlocal c = true\nif c then\n  x = 's'\nelse\n  x = 2\nend\nreturn x\n")
        T.eq(tys.x, "number | string", "phi(x) = string | number")
    end)

    T.it("if x then narrows x truthy; else keeps the falsy part", function()
        -- y captures the narrowed x inside each arm.
        local src = "local x = nil\nlocal c = true\nif c then x = 1 end\n"
            .. "local y = nil\nlocal z = nil\nif x then y = x else z = x end\nreturn y, z\n"
        local tys = infer(src)
        T.eq(tys.y, "nil | number", "then-arm sees truthy(x) = number (joined with y's initial nil)")
        T.eq(tys.z, "nil", "else-arm sees falsy(x) = nil")
    end)

    T.it("`not x` swaps the arms", function()
        local src = "local x = nil\nlocal c = true\nif c then x = 1 end\n"
            .. "local y = nil\nif not x then y = x end\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "nil", "then-arm of `not x` sees falsy(x)")
    end)

    T.it("elseif chains narrow per clause", function()
        local src = "local x = nil\nlocal c = true\nif c then x = 1 end\n"
            .. "local y = nil\nif c then y = 0 elseif x then y = x end\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "nil | number", "elseif arm sees truthy(x); merge joins with nil")
    end)
end)

T.describe("v9 lowering — the honest dynamism boundary", function()
    T.it("unsupported constructs produce structured diags with line/col", function()
        local _, diags = infer("local a = 1\nwhile a do\n  a = a\nend\n")
        local d = find_diag(diags, "unsupported:while-stmt")
        T.ok(d ~= nil, "while is flagged, not crashed on or silently passed")
        if d ~= nil then
            T.eq(d.line, 2, "line of the while")
            T.eq(d.col, 1, "col of the while")
        end
    end)

    T.it("locals assigned inside an unchecked region are HAVOCED to unknown", function()
        local tys = infer("local x = 1\nlocal c = true\nwhile c do\n  x = 's'\nend\nreturn x\n")
        T.eq(tys.x, "unknown", "the checked discipline stays sound around the boundary")
    end)

    T.it("undeclared globals are flagged at the use site", function()
        local _, diags = infer("local x = whatever\nreturn x\n")
        local d = find_diag(diags, "undeclared-global")
        T.ok(d ~= nil, "undeclared global flagged")
        if d ~= nil then
            T.eq(d.line, 1, "line")
            T.eq(d.col, 11, "col of the identifier")
        end
    end)

    T.it("unused locals are flagged at the declaration (params + _names exempt)", function()
        local _, diags = infer("local unused = 1\nlocal _ignored = 2\nlocal f = function(cb) return 0 end\nreturn f\n")
        local d = find_diag(diags, "unused-local")
        T.ok(d ~= nil and d.line == 1, "unused local flagged at its declaration")
        local count = 0
        for i = 1, #diags do
            if diags[i].code == "unused-local" then count = count + 1 end
        end
        T.eq(count, 1, "_ignored and the param cb are exempt")
    end)
end)

T.describe("v9 lowering — structural records", function()
    T.it("constructor -> field read roundtrip", function()
        local tys = infer("local t = { x = 1, s = 'a' }\nlocal y = t.x\nlocal z = t.s\nreturn y, z, t\n")
        T.eq(tys.t, "{ s: string, x: number }", "the constructor IS a record type")
        T.eq(tys.y, "number", "t.x projects the field type")
        T.eq(tys.z, "string", "t.s projects the field type")
    end)

    T.it("the module idiom: `function M.f()` accretes fields flow-sensitively", function()
        local tys, diags = infer("local M = {}\nfunction M.f() return 1 end\nM.g = 2\nlocal h = M.f\nreturn M, h\n")
        T.eq(tys.M, "{ f: () -> number, g: number }", "field writes extend the open record (arrows precise)")
        T.eq(tys.h, "() -> number", "reading an accreted field keeps the arrow")
        T.eq(find_diag(diags, "unsupported:field-assign"), nil, "field-assign is no longer a boundary bucket")
    end)

    T.it("phi of two records joins pointwise on common fields", function()
        local src = "local c = true\nlocal t = nil\n"
            .. "if c then t = { a = 1, b = 2 } else t = { a = 's', b = 3 } end\nreturn t\n"
        local tys = infer(src)
        T.eq(tys.t, "{ a: number | string, b: number }", "pointwise join at the merge")
    end)

    T.it("records ride the existing truthiness narrowing (optional-table idiom)", function()
        local src = "local c = true\nlocal t = nil\nif c then t = { x = 1 } end\n"
            .. "local v = nil\nif t then v = t.x end\nreturn v, t\n"
        local tys = infer(src)
        T.eq(tys.t, "nil | { x: number }", "nil | record stays precise at the merge")
        T.eq(tys.v, "nil | number", "truthy(t) is the record; t.x projects inside the guard")
    end)

    T.it("`local v = t.x; if v then` narrows the projected value", function()
        local src = "local c = true\nlocal t = { x = 1 }\nif c then t = { x = nil } end\n"
            .. "local v = t.x\nlocal y = nil\nif v then y = v end\nreturn y, t\n"
        local tys = infer(src)
        T.eq(tys.y, "nil | number", "the guard drops v's nil part (joined with y's initial nil)")
    end)

    T.it("field writes inside unchecked regions HAVOC the base (soundness fence)", function()
        local tys = infer("local t = { x = 1 }\nlocal c = true\nwhile c do\n  t.x = 2\nend\nreturn t\n")
        T.eq(tys.t, "unknown", "a record type must not survive unchecked mutation")
    end)

    T.it("dynamic keys are the honest `unsupported:dynamic-index` boundary", function()
        local _, diags = infer("local t = { x = 1 }\nlocal k = 'x'\nlocal v = t[k]\nreturn v\n")
        local d = find_diag(diags, "unsupported:dynamic-index")
        T.ok(d ~= nil, "non-literal index is flagged, not guessed at")
        if d ~= nil then
            T.eq(d.line, 3, "line of the index")
        end
    end)

    T.it("t[\"x\"] IS t.x (literal-string index = field)", function()
        local tys, diags = infer("local t = { x = 1 }\nlocal v = t[\"x\"]\nreturn v\n")
        T.eq(tys.v, "number", "literal-string keys project like dot access")
        T.eq(find_diag(diags, "unsupported:dynamic-index"), nil, "no boundary diag")
    end)

    T.it("the array part is the honest `unsupported:table-array-part` boundary", function()
        local tys, diags = infer("local t = { 1, 2, named = 's' }\nlocal v = t.named\nreturn v, t\n")
        T.ok(find_diag(diags, "unsupported:table-array-part") ~= nil, "array part flagged")
        T.eq(tys.v, "string", "named fields of a mixed constructor still check")
    end)
end)

T.describe("v9 lowering — function types + intra-file inference", function()
    T.it("params are inferred from call sites (cells-as-unknowns)", function()
        local tys = infer("local function f(a) return a end\nlocal x = f(1)\nlocal y = f('s')\nreturn x, y\n")
        T.eq(tys.f, "(?) -> number | string", "param cell joins the call-site arguments")
        T.eq(tys.x, "number | string", "the result flows back out")
    end)

    T.it("return types are inferred from return statements", function()
        local tys = infer("local c = true\nlocal function f()\n  if c then return 1 end\n  return 's'\nend\nlocal r = f()\nreturn r\n")
        T.eq(tys.f, "() -> number | string", "both returns join at the result cell")
        T.eq(tys.r, "number | string", "call result is the arrow's result")
    end)

    T.it("multi-return: contextual truncation + nil extension", function()
        local src = "local function f() return 1, 's' end\n"
            .. "local a = f()\nlocal b, c, d = f()\nreturn a, b, c, d\n"
        local tys = infer(src)
        T.eq(tys.f, "() -> (number, string)", "two result positions")
        T.eq(tys.a, "number", "expression position truncates to the first result")
        T.eq(tys.b, "number", "spread position 1")
        T.eq(tys.c, "string", "spread position 2")
        T.eq(tys.d, "nil", "past the arity: Lua pads with nil, NOT unknown")
    end)

    T.it("mixed return arities pad the short return with nil", function()
        local tys = infer("local c = true\nlocal function f()\n  if c then return 1 end\n  return 1, 's'\nend\nlocal _, b = f()\nreturn b\n")
        T.eq(tys.f, "() -> (number, nil | string)", "position 2 is nil on the short path")
    end)

    T.it("a call in last return position marks the arrow result-OPEN", function()
        local src = "local function g() return 1 end\nlocal function f() return g() end\n"
            .. "local a, b = f()\nreturn a, b\n"
        local tys = infer(src)
        T.eq(tys.a, "number", "the forwarded first result is precise")
        T.eq(tys.b, "unknown", "positions beyond are unknown (forwarding is open), not nil")
    end)

    T.it("arguments beyond the param list are checked-lowered but dropped; missing args pad nil", function()
        local tys = infer("local function f(a, b) return b end\nlocal r = f(1)\nreturn r\n")
        T.eq(tys.r, "nil", "the missing argument reaches the body as nil")
    end)

    T.it("`require(...)` is the honest cross-module boundary", function()
        local _, diags = infer("local m = require('lib.foo')\nreturn m\n")
        local d = find_diag(diags, "unsupported:cross-module")
        T.ok(d ~= nil, "require flagged as the module boundary")
        T.eq(find_diag(diags, "undeclared-global"), nil,
            "not double-reported as an undeclared global")
        local tys = infer("local m = require('lib.foo')\nreturn m\n")
        T.eq(tys.m, "unknown", "the required module's type is unknown (no summaries yet)")
    end)

    T.it("phi of two different functions collapses to the function top (calls unchecked but flagged)", function()
        local src = "local c = true\nlocal function f(a) return 1 end\nlocal function g(a) return 's' end\n"
            .. "local h = nil\nif c then h = f else h = g end\nlocal r = h(1)\nreturn r\n"
        local tys = infer(src)
        T.eq(tys.h, "function", "different arrows join to the function top")
        T.eq(tys.r, "unknown", "calls through the top are unknown (narrow to check)")
    end)

    T.it("higher-order flow: a function passed as an argument is callable inside", function()
        local src = "local function apply(fn) return fn(2) end\n"
            .. "local function double(n) return n end\nlocal r = apply(double)\nreturn r\n"
        local tys = infer(src)
        T.eq(tys.r, "number", "the callback's arrow flows through the param cell")
    end)
end)

T.describe("v9 lowering — totality roster", function()
    T.it("routes ALL 30 node kinds (checked / boundary / container)", function()
        local n = 0
        for tag = 0, frontend.NODE_KIND_COUNT - 1 do
            local route = lower.ROUTE[tag]
            T.ok(route == "checked" or route == "boundary" or route == "container",
                "kind " .. frontend.node_name(tag) .. " is routed (" .. tostring(route) .. ")")
            n = n + 1
        end
        T.eq(n, 30, "all 30 kinds routed")
    end)

    T.it("local function recursion terminates and infers honestly", function()
        -- f never returns a value along any path that terminates: its result
        -- is genuinely `never` (a bottom cycle), and the trailing-call spread
        -- marks the arrow result-open. The fixpoint TERMINATES (clip bounds
        -- the recursion-created value cycle).
        local tys = infer("local function f(n)\n  return f(n)\nend\nlocal r = f(1)\nreturn r\n")
        T.eq(tys.f, "(?) -> (never, ...)", "local function binds itself; param inferred from the call sites")
        T.eq(tys.r, "never", "a call that provably never returns has result never")
    end)
end)
