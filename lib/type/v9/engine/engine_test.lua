-- lib/type/v9/engine/engine_test.lua
-- End-to-end proof that ONE monotone-fixpoint engine drives three genuinely
-- different analyses over a SHARED, annotation-free program:
--   (a) the engine is domain-agnostic   — the SAME `engine.solve` solves all
--       three lowered graphs; the domains share no symbols and never import each
--       other (decoupling is structural, shown here by driving one solver);
--   (b) the type domain INFERS without annotations (x : int | str falls out of
--       the join at the if-merge);
--   (c) the constant-propagation domain — a NON-set-union lattice with a real ⊤
--       and a folding transfer — works through the SAME engine + interface (the
--       pressure test the spikes never ran).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

--:: require "lib.type.v9.engine.defs"

local T = require("lib.test.assert")
local engine = require("lib.type.v9.engine.engine")
local cfg = require("lib.type.v9.engine.cfg")
local dataflow = require("lib.type.v9.engine.dataflow")
local surface = require("lib.type.v9.engine.surface")
local types = require("lib.type.v9.engine.domain.types")
local liveness = require("lib.type.v9.engine.domain.liveness")
local constprop = require("lib.type.v9.engine.domain.constprop")

T.describe("v9 engine — type inference (annotation-free)", function()
    T.it("infers x : int | str from the if-merge with zero annotations", function()
        local facts, err = types.analyze(surface.program())
        T.ok(facts ~= nil, "inference ran: " .. (err or ""))
        if facts ~= nil then
            T.eq(facts.vars["x"], "int | str", "x is the union of the two branch assignments")
            T.eq(facts.vars["y"], "int", "y = x + 1 is int")
            T.eq(facts.result, "int | str", "the inferred return type is int | str")
        end
    end)
end)

T.describe("v9 engine — liveness (backward gen/kill)", function()
    T.it("finds the free var live at entry and the unused locals", function()
        local facts, err = liveness.analyze(surface.program())
        T.ok(facts ~= nil, "liveness ran: " .. (err or ""))
        if facts ~= nil then
            T.eq(facts.live_at_entry["cond"], true, "free var `cond` is live at entry")
            T.eq(facts.unused["dead"], true, "`dead` is never read")
            T.eq(facts.unused["x"], nil, "`x` is used (not unused)")
        end
    end)
end)

T.describe("v9 engine — constant propagation (pressure test: non-set-union lattice)", function()
    T.it("folds y = 2 and joins x to ⊤ through the same engine + interface", function()
        local facts, err = constprop.analyze(surface.program())
        T.ok(facts ~= nil, "constprop ran: " .. (err or ""))
        if facts ~= nil then
            T.eq(facts.env["y"], "num(2)", "y = x + 1 const-folds to 2")
            T.eq(facts.env["x"], "top", "x joins to ⊤ (lossy join of distinct branch values)")
            T.eq(facts.env["dead"], "num(9)", "dead = 9 is a known constant")
        end
    end)
end)

T.describe("v9 engine — domain-agnostic (one solver drives all three)", function()
    T.it("the SAME engine.solve solves the type, liveness, and constprop graphs", function()
        local program = surface.program() --: Program

        -- Type domain lowers directly to a cells-as-unknowns graph.
        local type_graph = types.lower(program).graph
        local ts, terr = engine.solve(type_graph)
        T.ok(ts ~= nil, "engine.solve handled the inference graph: " .. (terr or ""))

        -- Flow domains lower via the shared CFG + dataflow adapter; the only
        -- difference between them is `direction` (a preds/succs swap).
        local g = cfg.lower(program)
        local live_graph = dataflow.to_graph(g, liveness.domain)
        local const_graph = dataflow.to_graph(g, constprop.domain)
        local ls, lerr = engine.solve(live_graph)
        local cs, cerr = engine.solve(const_graph)
        T.ok(ls ~= nil, "engine.solve handled the liveness graph: " .. (lerr or ""))
        T.ok(cs ~= nil, "engine.solve handled the constprop graph: " .. (cerr or ""))

        T.eq(liveness.domain.direction, "backward", "liveness is backward")
        T.eq(constprop.domain.direction, "forward", "constprop is forward")
    end)
end)
