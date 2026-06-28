-- lib/type/v9/parity_test.lua
-- Two disciplines, from day one:
--   (1) PROOF-ORACLE PARITY — the structural decider's verdicts are checked
--       against ground truth lifted from the proof relations (subtype.v /
--       ssub.v). Each case cites the proof fact it encodes.
--   (2) MODULARITY IS REAL — seams actually swap:
--         * type representation: tagged vs interned give identical verdicts
--           (the rep interface does not leak);
--         * subtyping backend: structural vs reflexive behind one interface;
--         * full pipeline assembled from swapped impls still runs.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local v9 = require("lib.type.v9")
local tagged = require("lib.type.v9.type_rep.tagged")
local interned = require("lib.type.v9.type_rep.interned")
local structural = require("lib.type.v9.subtype.structural")
local reflexive = require("lib.type.v9.subtype.reflexive")

--:: require "lib.type.v9.type_defs"
--:: CheckerT = { check_source: (string) -> (CheckResult | nil, Diag | nil), check_source_against: (string, string) -> (CheckResult | nil, Diag | nil), impls: Impls }

-- Build a small battery of (a, b) type pairs over an arbitrary rep, so the same
-- logical cases can be replayed against any representation impl.
--: (TypeRep) -> { [integer]: { a: Ty, b: Ty, expect: Decision, why: string } }
local function cases(rep)
    local int = rep.atom("int")
    local num = rep.atom("num")
    local str = rep.atom("str")
    return {
        -- atom base order — subtype.v: AInt <: ANum (baked base order).
        { a = int, b = num, expect = "sub", why = "int <: num (subtype.v base order)" },
        { a = num, b = int, expect = "notsub", why = "num </: int (converse fails)" },
        { a = int, b = int, expect = "sub", why = "reflexivity (ssub_refl)" },
        -- distinct atom heads denote disjoint sets (subtype.v: distinct heads unrelated).
        { a = str, b = num, expect = "notsub", why = "str </: num (disjoint atoms)" },
        -- arrows — BArrow: contravariant dom, covariant cod.
        { a = rep.arrow(num, int), b = rep.arrow(int, num), expect = "sub",
          why = "(num->int) <: (int->num): int<:num dom, int<:num cod" },
        { a = rep.arrow(int, num), b = rep.arrow(num, int), expect = "notsub",
          why = "(int->num) </: (num->int): num</:int domain" },
        -- unions — has_type TIf result / subtype.v union laws.
        { a = int, b = rep.union(int, str), expect = "sub", why = "int <: (int | str)" },
        { a = rep.union(int, str), b = num, expect = "notsub", why = "(int|str) </: num (str arm fails)" },
        -- references — subtype.v increment 6 CORRECTED: ref clauses DEFER (gdecide
        -- => DUnknown). Equal refs are still reflexively sub; differing refs defer.
        { a = rep.ref(int), b = rep.ref(int), expect = "sub", why = "ref(int) <: ref(int) by reflexivity" },
        { a = rep.ref(int), b = rep.ref(num), expect = "unknown",
          why = "ref(int) vs ref(num): DEFERRED (gdecide DUnknown on refs)" },
    }
end

T.describe("v9 proof-oracle parity (structural decider vs proof relations)", function()
    T.it("matches ground truth lifted from subtype.v / ssub.v", function()
        local battery = cases(tagged)
        for i = 1, #battery do
            local c = battery[i]
            local got = structural.decide(tagged, c.a, c.b)
            T.eq(got, c.expect, c.why)
        end
    end)
end)

T.describe("v9 modularity is real (seams actually swap)", function()
    T.it("type representation does not leak: tagged vs interned agree", function()
        local tg = cases(tagged)
        local it = cases(interned)
        for i = 1, #tg do
            local got_tagged = structural.decide(tagged, tg[i].a, tg[i].b)
            local got_interned = structural.decide(interned, it[i].a, it[i].b)
            T.eq(got_tagged, got_interned, "tagged/interned agree: " .. tg[i].why)
            T.eq(got_interned, tg[i].expect, "interned also matches the proof oracle")
        end
    end)

    T.it("subtyping backend swaps: reflexive is sound but more deferring", function()
        local int = tagged.atom("int")
        local num = tagged.atom("num")
        -- Both backends commit "sub" where the proof is certain by refl/base-order.
        T.eq(structural.decide(tagged, int, num), "sub", "structural: int <: num")
        T.eq(reflexive.decide(tagged, int, num), "sub", "reflexive: int <: num (base order)")
        -- On a query needing structural reasoning, reflexive honestly DEFERS while
        -- structural decides — same interface, different precision, both sound.
        local af = tagged.arrow(num, int)
        local bf = tagged.arrow(int, num)
        T.eq(structural.decide(tagged, af, bf), "sub", "structural decides the arrow")
        T.eq(reflexive.decide(tagged, af, bf), "unknown", "reflexive defers the arrow (never wrong)")
    end)

    T.it("full pipeline assembled from SWAPPED impls still runs", function()
        local impls = {
            rep = interned,
            sub = reflexive,
            infer = require("lib.type.v9.infer.bidir"),
            diag = require("lib.type.v9.diagnostics"),
            cert = require("lib.type.v9.certificate"),
            parser = require("lib.type.v9.parser"),
        } --: Impls
        local checker = v9.new(impls) --: CheckerT
        local res, err = checker.check_source("((lambda (x Int) x) 42)")
        T.ok(res ~= nil, "interned-rep + reflexive-decider pipeline checks identity app: "
            .. (err and err.message or ""))
        if res ~= nil then T.eq(interned.show(res.type), "int", "result type via swapped rep") end
        -- A subsumption needing ARROW reasoning is beyond reflexive: it surfaces as
        -- honest deferral (subtype_unprovable), never a fail-optimistic accept.
        local ok2, derr = checker.check_source_against("(lambda (x Int) x)", "(-> Int Num)")
        T.ok(ok2 == nil and derr ~= nil and derr.code == "subtype_unprovable",
            "reflexive defers (int->int) <: (int->num) as unprovable")
    end)
end)
