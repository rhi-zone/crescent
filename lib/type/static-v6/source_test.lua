-- lib/type/static-v6/source_test.lua
-- M1 direct-arena source checker tests.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local source = require("lib.type.static-v6.source")

--: (string) -> unknown
local function check(src)
    return source.check_string(src, "source_test.lua")
end

T.describe("v6 source M1", function()
    T.it("returns parse errors as diagnostics", function()
        local res = check("local =\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "PARSE_ERROR")
    end)

    T.it("rejects declarations and orphan annotations", function()
        local res = check("--:: Foo = number\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "FEATURE_NOT_ADMITTED")
        T.eq(res.diagnostics[1].details.span.line, 1)

        res = check("--: @@@\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "ANNOTATION_PARSE_ERROR")
        T.eq(res.diagnostics[1].details.span.line, 1)

        res = check("--: number\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "ANNOTATION_NOT_ATTACHED")
        T.eq(res.diagnostics[1].details.span.line, 1)
    end)

    T.it("checks literal local inference and assignment", function()
        local res = check("--: number\nlocal x = 1\nx = 2\n")
        T.eq(res.ok, true)
        T.eq(res.env.bindings.x.tag, "atom")
        T.eq(res.env.bindings.x.name, "number")
    end)

    T.it("checks preceding-line local annotations transactionally", function()
        local res = check("--: number\nlocal x = 1\n")
        T.eq(res.ok, true)
        T.eq(res.env.bindings.x.tag, "atom")
        T.eq(res.env.bindings.x.name, "number")

        res = check("--: number\nlocal bad = 'x'\n")
        T.eq(res.ok, false)
        T.eq(res.env.bindings.bad, nil)
        T.eq(res.diagnostics[1].code, "TYPE_MISMATCH")
        T.eq(res.diagnostics[1].details.obligation_reason, "local annotation")
        T.eq(res.diagnostics[1].details.obligation_span.line, 2)
    end)

    T.it("checks same-line local annotations", function()
        local res = check("local s = 'x' --: string\n")
        T.eq(res.ok, true)
        T.eq(res.env.bindings.s.tag, "atom")
        T.eq(res.env.bindings.s.name, "string")
    end)

    T.it("checks uninitialized annotated locals against nil", function()
        local res = check("local n --: number\n")
        T.eq(res.ok, false)
        T.eq(res.env.bindings.n, nil)
        T.eq(res.diagnostics[1].code, "TYPE_MISMATCH")

        res = check("local n --: number | nil\n")
        T.eq(res.ok, true)
        T.eq(res.env.bindings.n.tag, "union")
    end)

    T.it("rejects undeclared assignment targets", function()
        local res = check("x = 1\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "UNDECLARED_BINDING")
    end)

    T.it("checks assignment against existing binding claim", function()
        local res = check("--: number\nlocal x = 1\nx = 's'\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "TYPE_MISMATCH")
    end)

    T.it("checks assignment annotations without changing target binding", function()
        local res = check("local s = 'x'\n--: number\ns = 'y'\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "TYPE_MISMATCH")
        T.eq(res.env.bindings.s.base, "string")
    end)

    T.it("checks checked casts and records force casts", function()
        local res = check("local x = --[[: string]] 's'\n")
        T.eq(res.ok, true)
        T.eq(res.env.bindings.x.name, "string")

        res = check("local y = --[[: string]] 1\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "TYPE_MISMATCH")

        res = check("local z = --[[:! string]] 1\n")
        T.eq(res.ok, true)
        T.eq(res.env.bindings.z.name, "string")
        T.eq(#res.env.unsafe_boundaries, 1)
    end)

    T.it("keeps multiple force-cast annotations distinct", function()
        local res = check("local x = --[[:! string]] 1\nlocal y = --[[:! number]] 2\n")
        T.eq(res.ok, true)
        T.eq(res.env.bindings.x.name, "string")
        T.eq(res.env.bindings.y.name, "number")
        T.eq(#res.env.unsafe_boundaries, 2)
    end)

    T.it("rejects multi-binding shapes instead of guessing Lua adjustment", function()
        local res = check("local a, b = 1, 2\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "FEATURE_NOT_ADMITTED")
    end)

    T.it("rejects extra rhs arity instead of guessing Lua adjustment", function()
        local res = check("local a = 1, 2\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "FEATURE_NOT_ADMITTED")
    end)

    T.it("reports malformed annotations even when attached shape is unsupported", function()
        local res = check("--: @@@\nlocal a, b = 1, 2\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "FEATURE_NOT_ADMITTED")
        T.eq(res.diagnostics[2].code, "ANNOTATION_PARSE_ERROR")
    end)

    T.it("reports valid annotations on unsupported shapes as unattached", function()
        local res = check("--: number\nlocal a, b = 1, 2\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "FEATURE_NOT_ADMITTED")
        T.eq(res.diagnostics[2].code, "ANNOTATION_NOT_ATTACHED")
        T.eq(res.diagnostics[2].details.span.line, 1)
    end)

    T.it("does not let annotations spill past an unsupported statement", function()
        local res = check("--: number\nfoo()\nlocal x = 's'\n")
        T.eq(res.ok, false)
        T.eq(res.diagnostics[1].code, "FEATURE_NOT_ADMITTED")
        T.eq(res.diagnostics[2].code, "ANNOTATION_NOT_ATTACHED")
        T.eq(res.env.bindings.x.base, "string")
    end)
end)
