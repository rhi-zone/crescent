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

    T.it("local function recursion + shallow calls check", function()
        local tys = infer("local function f(n)\n  return f(n)\nend\nlocal r = f(1)\nreturn r\n")
        T.eq(tys.f, "function", "local function binds itself")
        T.eq(tys.r, "unknown", "v0 calls are shallow: result is unknown, to be narrowed")
    end)
end)
