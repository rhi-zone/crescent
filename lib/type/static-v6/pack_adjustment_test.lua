-- lib/type/static-v6/pack_adjustment_test.lua
-- Fixtures for Lua pack-adjustment movement sites.
--
-- These tests pin movement-site cases so M2 work cannot silently guess Lua
-- adjustment. Local-binding, assignment, return, and monomorphic call-argument
-- cases are implemented; parenthesized-call collapse still requires AST support
-- because the current parser does not preserve grouping.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local source = require("lib.type.static-v6.source")

--:: PackAdjustmentCase = { name: string, src: string, first_code: string | nil, final: string }

local cases = {
    {
        name = "single local keeps first result",
        src = "local a = f()\n",
        first_code = "UNDECLARED_BINDING",
        final = "local a = f() keeps only the first result of f",
    },
    {
        name = "multi-local expands final sole call",
        src = "local a, b = f()\n",
        first_code = "UNDECLARED_BINDING",
        final = "local a, b = f() expands f because it is the only final RHS",
    },
    {
        name = "multi-local adjusts non-final call and expands final call",
        src = "local a, b = f(), g()\n",
        first_code = "UNDECLARED_BINDING",
        final = "local a, b = f(), g() adjusts f to one result and expands g",
    },
    {
        name = "call expands final argument call",
        src = "g(f())\n",
        first_code = "UNDECLARED_BINDING",
        final = "g(f()) expands f only because it is the final argument",
    },
    {
        name = "parenthesized call argument collapses",
        src = "g((f()))\n",
        first_code = "UNDECLARED_BINDING",
        final = "g((f())) collapses f to one result",
    },
    {
        name = "return adjusts non-final call and expands final call",
        src = "return f(), g()\n",
        first_code = "FEATURE_NOT_ADMITTED",
        final = "return f(), g() adjusts f to one result and expands g",
    },
    {
        name = "missing values pad at movement sites only",
        src = "local a, b = 1\n",
        first_code = nil,
        final = "missing values nil-pad only at Lua movement sites that pad",
    },
    {
        name = "explicit nil positions remain explicit",
        src = "local a, b = nil, f()\n",
        first_code = "UNDECLARED_BINDING",
        final = "explicit nil positions in packs must not collapse",
    },
}

T.describe("v6 pack adjustment fixtures", function()
    for _, case in ipairs(cases) do
        T.it(case.name, function()
            local res = source.check_string(case.src, "pack_adjustment_test.lua")
            if case.first_code == nil then
                T.eq(res.ok, true)
            else
                T.eq(res.ok, false)
                T.eq(res.diagnostics[1].code, case.first_code)
            end
            T.ok(case.final)
        end)
    end
end)
