-- lib/type/v9/slice_test.lua
-- Minimal END-TO-END slice: source -> de-Bruijn IR -> synth/check ->
-- subtype-decide (three-valued) -> diagnostic. Proves the seams COMPOSE and
-- that the path actually runs. Intentionally tiny (literals, lambda, app, let).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local v9 = require("lib.type.v9")
local tagged = require("lib.type.v9.type_rep.tagged")

--:: require "lib.type.v9.type_defs"
--:: CheckerT = { check_source: (string) -> (CheckResult | nil, Diag | nil), check_source_against: (string, string) -> (CheckResult | nil, Diag | nil), impls: Impls }

local checker = v9.new(nil) --: CheckerT

--: (string) -> string
local function type_of(src)
    local res, err = checker.check_source(src)
    if res == nil then error("expected success for [" .. src .. "], got: " .. (err and err.message or "?")) end
    return tagged.show(res.type)
end

--: (string) -> Diag
local function error_of(src)
    local res, err = checker.check_source(src)
    if err == nil then error("expected failure for [" .. src .. "]") end
    return err
end

T.describe("v9 minimal end-to-end slice", function()
    T.it("synthesizes literal types", function()
        T.eq(type_of("42"), "int", "int literal")
        T.eq(type_of('"hi"'), "str", "string literal")
        T.eq(type_of("true"), "bool", "bool literal")
        T.eq(type_of("nil"), "nil", "nil literal")
    end)

    T.it("synthesizes a lambda as an arrow", function()
        T.eq(type_of("(lambda (x Int) x)"), "(int -> int)", "identity arrow")
        T.eq(type_of("(lambda (x Int) 42)"), "(int -> int)", "const arrow")
    end)

    T.it("synthesizes application via the arrow", function()
        T.eq(type_of("((lambda (x Int) x) 42)"), "int", "applied identity")
    end)

    T.it("synthesizes let-binding", function()
        T.eq(type_of("(let (x 42) x)"), "int", "let returns body type")
    end)

    T.it("checks against an expected type via subsumption (int <: num)", function()
        local res, err = checker.check_source_against("42", "Num")
        T.ok(res ~= nil, "int checks against Num: " .. (err and err.message or ""))
    end)

    T.it("rejects a definite subtype failure with a diagnostic", function()
        local err = error_of("((lambda (x Str) x) 42)")
        T.eq(err.code, "type_mismatch", "applying int where str expected")
    end)

    T.it("rejects checking int against Str", function()
        local res, err = checker.check_source_against("42", "Str")
        T.ok(res == nil, "int does not check against Str")
        if err ~= nil then T.eq(err.code, "type_mismatch", "mismatch code") end
    end)

    T.it("reports unbound variables (caught at the lowering seam)", function()
        local err = error_of("y")
        T.eq(err.code, "lower_error", "free variable rejected during name resolution")
        T.ok(err.message:find("unbound", 1, true) ~= nil, "message names the unbound variable")
    end)

    T.it("exposes first-class derivation evidence", function()
        local res = checker.check_source("((lambda (x Int) x) 42)")
        T.ok(res ~= nil, "checked")
        if res ~= nil then
            T.eq(res.deriv.rule, "TApp", "root rule is application")
            T.ok(#res.deriv.premises == 2, "app derivation has function + argument premises")
            T.ok(res.cert ~= nil, "a (no-op) certificate was emitted from the derivation")
        end
    end)

    T.it("names are non-semantic: alpha-equivalent terms lower identically", function()
        local a = checker.check_source("(lambda (x Int) x)")
        local b = checker.check_source("(lambda (zzz Int) zzz)")
        T.ok(a ~= nil and b ~= nil, "both lower")
        if a ~= nil and b ~= nil then
            T.eq(tagged.show(a.type), tagged.show(b.type), "renaming the binder does not change the type")
        end
    end)
end)
