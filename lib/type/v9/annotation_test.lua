-- lib/type/v9/annotation_test.lua
-- Annotations end to end: PIN + CHECK (an annotation is both a seed and an
-- upper-bound obligation — inference must AGREE, never be overridden), the
-- arrow variance proof (contravariant params reject a narrower function
-- where a wider one is promised), checked/force casts, and the two known
-- real-code findings (keyring._tier / server_ws res.body) that resolve once
-- `--: T | nil` annotations are read.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local check = require("lib.type.v9.check")

--:: ADiag = { code: string, severity: string, message: string, line: integer, col: integer }

--: ({ [integer]: ADiag }, string) -> ADiag | nil
local function find_diag(diags, code)
    for i = 1, #diags do
        if diags[i].code == code then return diags[i] end
    end
    return nil
end

--: ({ [integer]: ADiag }) -> string
local function render(diags)
    local parts = {} --: { [integer]: string }
    for i = 1, #diags do
        parts[#parts + 1] = diags[i].line .. ":" .. diags[i].code
    end
    return table.concat(parts, " ")
end

T.describe("v9 annotations — pin + check on locals", function()
    T.it("an annotation the initializer violates is an error with line/col", function()
        local diags = check.check_source("local x = 'oops' --: number\nreturn x\n", "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "annotation-mismatch")
            T.ok(d ~= nil, "inference disagrees -> error, never silently overridden")
            if d ~= nil then
                T.eq(d.severity, "error", "error by default")
                T.eq(d.line, 1, "at the declaration")
                T.ok(d.message:find("number", 1, true) ~= nil, "names the annotation: " .. d.message)
            end
        end
    end)

    T.it("the pin SEEDS the cell: readers see the annotated type", function()
        -- Without the annotation x is nil-initialized; with it, arithmetic
        -- on x checks against number | nil (excess nil), not against nil.
        local diags = check.check_source(
            "local x --: number | nil\nlocal y = nil\nif x then y = x + 1 end\nreturn y\n", "t.lua", nil)
        T.ok(diags ~= nil and #diags == 0,
            "narrowed annotated local is arithmetic-clean: " .. (diags ~= nil and render(diags) or "?"))
    end)

    T.it("assignments to an annotated local must agree AND narrow", function()
        local bad = check.check_source(
            "local s --: string | nil\ns = 42\nreturn s\n", "t.lua", nil)
        T.ok(bad ~= nil and find_diag(bad, "annotation-mismatch") ~= nil,
            "out-of-pin assignment rejected")
        local good = check.check_source(
            "local s --: string | nil\ns = 'a'\nlocal t = s .. 'b'\nreturn t\n", "t.lua", nil)
        T.ok(good ~= nil and #good == 0,
            "in-pin assignment narrows: s .. 'b' is clean after s = 'a' ("
                .. (good ~= nil and render(good) or "?") .. ")")
    end)

    T.it("annotations survive havoc (the loop-mutation idiom)", function()
        local src = "local acc = 0 --: number\nlocal c = true\nwhile c do\n  acc = acc + 1\nend\n"
            .. "local y = acc + 1\nreturn y\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.eq(find_diag(diags, "use-before-narrow"), nil,
                "the pin, not unknown, survives the unchecked region: " .. render(diags))
            T.eq(find_diag(diags, "op-mismatch"), nil, "acc + 1 stays clean")
        end
    end)
end)

T.describe("v9 annotations — function definitions (params + returns)", function()
    T.it("param pins check arguments at the CALL site", function()
        local src = "--: (a: number, b: string) -> string\nlocal function f(a, b)\n  return b\nend\n"
            .. "local ok = f(1, 'x')\nlocal bad = f('nope', 'y')\nreturn ok, bad\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "call-mismatch")
            T.ok(d ~= nil, "the bad argument is rejected")
            if d ~= nil then
                T.eq(d.line, 6, "at the offending call")
                T.ok(d.message:find("argument #1", 1, true) ~= nil, "names the position: " .. d.message)
            end
            T.eq(find_diag(diags, "unsupported:unconstrained-param"), nil,
                "pinned params are constrained by definition")
        end
    end)

    T.it("a missing argument is checked as Lua's nil pad", function()
        local src = "--: (a: number, b: string | nil) -> nil\nlocal function f(a, b)\n  return nil\nend\n"
            .. "f(1)\nreturn f\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil and #diags == 0,
            "nil ⊑ string | nil: underapplication with an optional param is clean")
        local src2 = "--: (a: number, b: string) -> nil\nlocal function f(a, b)\n  return nil\nend\n"
            .. "f(1)\nreturn f\n"
        local diags2 = check.check_source(src2, "t.lua", nil)
        T.ok(diags2 ~= nil and find_diag(diags2, "call-mismatch") ~= nil,
            "a required param rejects the nil pad")
    end)

    T.it("param pins seed the body (annotated params are usable, not unknown)", function()
        local src = "--: (n: number) -> number\nlocal function f(n)\n  return n + 1\nend\nreturn f\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil and #diags == 0,
            "n + 1 checks against the pin even with zero call sites")
    end)

    T.it("return pins check every return statement, per position, at its line", function()
        local src = "--: () -> (number, string)\nlocal function f()\n  local c = true\n"
            .. "  if c then\n    return 1, 2\n  end\n  return 1, 'ok'\nend\nreturn f\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "annotation-mismatch")
            T.ok(d ~= nil, "the number-for-string return is rejected")
            if d ~= nil then
                T.eq(d.line, 5, "at the offending return")
                T.ok(d.message:find("return value #2", 1, true) ~= nil, "names the position: " .. d.message)
            end
        end
    end)

    T.it("returns beyond the annotated result count are rejected", function()
        local src = "--: () -> number\nlocal function f()\n  return 1, 'extra'\nend\nreturn f\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil and find_diag(diags, "annotation-mismatch") ~= nil,
            "the annotation promises one result; the second is a lie one way or the other")
    end)

    T.it("callers see the ANNOTATED results (the interface, not re-inference)", function()
        local src = "--: () -> (string | nil, string | nil)\nlocal function f()\n  return 'v', nil\nend\n"
            .. "local v, e = f()\nlocal out = ''\nif v then out = v .. '!' end\nreturn out, e\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil and #diags == 0,
            "the (nil, errmsg) idiom round-trips through annotation + narrowing")
    end)
end)

T.describe("v9 annotations — arrow VARIANCE (the soundness proof)", function()
    T.it("REJECTS a narrower function where a wider one is promised (contravariant params)", function()
        -- g's annotation promises callers may pass number | string; f only
        -- accepts number. Admitting it would send strings into f's body.
        local src = "--: (x: number) -> nil\nlocal function f(x)\n  return nil\nend\n"
            .. "local g = f --: (x: number | string) -> nil\nreturn g\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "annotation-mismatch")
            T.ok(d ~= nil, "REJECTED — params are contravariant, not bivariant")
            if d ~= nil then
                T.eq(d.line, 5, "at the widening ascription")
            end
        end
    end)

    T.it("ACCEPTS a wider function where a narrower one is promised", function()
        local src = "--: (x: number | string) -> nil\nlocal function f(x)\n  return nil\nend\n"
            .. "local g = f --: (x: number) -> nil\nreturn g\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil and #diags == 0,
            "a function accepting MORE is usable where less is passed")
    end)

    T.it("results are covariant (narrower results flow; wider are rejected)", function()
        local src = "--: () -> number\nlocal function f()\n  return 1\nend\n"
            .. "local g = f --: () -> number | string\nreturn g\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil and #diags == 0, "() -> number ⊑ () -> number | string")
        local src2 = "--: () -> number | string\nlocal function f()\n  return 1\nend\n"
            .. "local g = f --: () -> number\nreturn g\n"
        local diags2 = check.check_source(src2, "t.lua", nil)
        T.ok(diags2 ~= nil and find_diag(diags2, "annotation-mismatch") ~= nil,
            "() -> number | string ⊄ () -> number")
    end)

    T.it("an annotated callback param checks the callback's body AND results", function()
        local src = "--: (cb: (number | string) -> nil) -> nil\nlocal function each(cb)\n"
            .. "  cb(1)\n  cb('s')\n  return nil\nend\n"
            .. "each(function(v)\n  local n = v + 1\n  return nil\nend)\nreturn each\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "op-mismatch")
            T.ok(d ~= nil and d.line == 8,
                "the pin seeds number | string into the callback: v + 1 is flagged in ITS body")
        end
    end)
end)

T.describe("v9 annotations — casts", function()
    T.it("a checked cast is an obligation AND narrows the flow", function()
        local src = "local a = 1 --: number | string\n"
            .. "local b = (a --[[: number]]) + 1\nreturn b\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "cast-mismatch")
            T.ok(d ~= nil and d.line == 2, "number | string ⊄ number: full subtyping required")
            T.eq(find_diag(diags, "op-mismatch"), nil,
                "the flow DID narrow to number — no cascade at the `+`")
        end
    end)

    T.it("a valid checked cast is silent", function()
        local src = "local a = 1 --: number\nlocal b = (a --[[: number | string]])\nreturn b\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil and #diags == 0, "upcast is fine: " .. (diags ~= nil and render(diags) or "?"))
    end)

    T.it("force casts are the named policy: error by default, dialable", function()
        local src = "local a = 1\nlocal b = (a --[[:! string]])\nreturn b\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "force-cast")
            T.ok(d ~= nil and d.severity == "error", "error by default (conventions)")
        end
        local lax = check.default_policy()
        lax["force-cast"] = "warn"
        local diags2 = check.check_source(src, "t.lua", { policy = lax, mode = nil })
        if diags2 ~= nil then
            local d2 = find_diag(diags2, "force-cast")
            T.ok(d2 ~= nil and d2.severity == "warn", "the dial is owner-decidable data")
        end
    end)
end)

T.describe("v9 annotations — the honest annotation boundary", function()
    T.it("non-v0 features are per-feature named buckets", function()
        local src = "local x = {} --: { [boolean]: number }\nlocal y = nil --: Arr<string>\nreturn x, y\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.ok(find_diag(diags, "unsupported:annotation-index-signature-key") ~= nil,
                "a non-string/number index KEY is named (string/number signatures are real types now)")
            T.ok(find_diag(diags, "unsupported:annotation-generic") ~= nil, "generic named")
        end
    end)

    T.it("index-signature annotations are REAL types (bucket retired)", function()
        local src = "local x = {} --: { [string]: number }\nreturn x\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.eq(find_diag(diags, "unsupported:annotation-index-signature"), nil, "no bucket")
            T.eq(#diags, 0, "a fresh {} ascribed to a map type is clean: " .. render(diags))
        end
    end)

    T.it("`--:: Name = T` aliases resolve inside annotations", function()
        local src = "--:: Res = { status: number, body: string | nil }\n"
            .. "local r = { status = 200, body = nil } --: Res\nr.body = 'hello'\nreturn r\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil and #diags == 0,
            "alias + init ascription + in-bound later write: "
                .. (diags ~= nil and render(diags) or "?"))
    end)

    T.it("`--:: require` is the cross-module boundary bucket", function()
        local diags = check.check_source("--:: require \"lib.foo\"\nreturn 1\n", "t.lua", nil)
        T.ok(diags ~= nil and find_diag(diags, "unsupported:cross-module") ~= nil, "named")
    end)
end)

T.describe("v9 annotations — the two known real-code findings RESOLVE", function()
    T.it("keyring shape: `M._tier = nil --: string | nil` accepts the later string write", function()
        -- lib/keyring/init.lua:28 + :778 — previously field-write-mismatch
        -- (the field's ref type was inferred from the nil initializer).
        local src = "local M = {}\nM._tier = nil --: string | nil\n"
            .. "local function load_backend()\n  M._tier = 'libsecret'\n  return M\nend\nreturn load_backend\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.eq(find_diag(diags, "field-write-mismatch"), nil,
                "the annotated field ref admits string | nil: " .. render(diags))
        end
    end)

    T.it("server_ws shape: constructor field nil then string, under a record alias", function()
        -- lib/http/server_ws.lua:34 + :56 — `body = nil` inside a
        -- constructor ascribed `--: WsHttpResponse` where body: string | nil.
        local src = "--:: Res = { status: number, headers: { [string]: string }, body: string | nil }\n"
            .. "local res = { status = 200, headers = {}, body = nil } --: Res\n"
            .. "res.status = 500\nres.body = '{\"error\":\"x\"}'\nreturn res\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.eq(find_diag(diags, "field-write-mismatch"), nil,
                "both later writes are in-bound: " .. render(diags))
            T.eq(find_diag(diags, "annotation-mismatch"), nil,
                "the nil initializer satisfies string | nil (initialization ascription)")
        end
    end)
end)
