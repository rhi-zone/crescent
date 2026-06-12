-- lib/type/analysis/slice_subtype_bench.lua
--
-- Performance benchmark for the `crescent.slice.v1` subtype relation
-- (docs/agnostic-static-analysis-crescent-slice.md §5.1, kernel §5.1 — highest
-- priority). Exercises the adversarial type shapes the kernel decision names:
-- deep μ nesting, wide unions/intersections, and the hamt-shaped recursive type.
--
-- The bar (§7.2): no single query approaches the timeout-30 ceiling; record
-- actual numbers. A query exceeding timeout-30 is a soundness/termination signal,
-- not a slow case. This script is a runnable (not a *_test.lua): invoke with
--   bin/cr run lib/type/analysis/slice_subtype_bench.lua
-- and paste the table into docs/perf/log.md.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local G = require("lib.type.analysis.slice_ty")
local S = require("lib.type.analysis.slice_subtype")

--: <T>(string, T, boolean | nil) -> { key: string, ty: T, optional: boolean, readonly: boolean }
local function fld(k, ty, optional)
	return { key = k, ty = ty, optional = optional or false, readonly = false }
end

-- ── Adversarial shape builders ───────────────────────────────────────────────

-- The hamt-shaped recursive type (§6.2): μX. (Leaf | Interior(X)).
--: () -> Ty
local function hamt()
	return G.mu("X", function(x)
		local leaf = G.rec({ fld("kind", G.integer()), fld("key", G.unknown()) }, "closed")
		local interior = G.rec({ fld("kind", G.integer()), fld("children", G.indexer(G.integer(), x)) }, "closed")
		return G.union({ leaf, interior })
	end)
end

-- Deeply NESTED μ: μX0. { next: μX1. { next: ... { next: X_k | nil } } | nil }.
-- Each level recurses on its own binder; the innermost references the outermost
-- by nesting. Stresses unfold + the cycle guard across many binders.
--: (integer) -> Ty
local function deep_mu(depth)
	--: (integer) -> Ty
	local function build(d)
		return G.mu("X", function(x)
			if d <= 0 then
				return G.union({ G.nil_(), G.rec({ fld("next", x) }, "closed") })
			end
			return G.union({ G.nil_(), G.rec({ fld("next", x), fld("down", build(d - 1)) }, "closed") })
		end)
	end
	return build(depth)
end

-- WIDE union: a union of `n` distinct literal singletons.
--: (integer) -> Ty
local function wide_union(n)
	local ms = {} --[[: { [integer]: Ty } ]]
	for i = 1, n do ms[#ms + 1] = G.lit_int(i) end
	return G.union(ms)
end

-- SHARED-SUBTERM DAG: a `{ a: child, b: child }` chain of depth `n` where both
-- fields point at the SAME interned child (audit round 1, finding 4). Without
-- per-query memoization, the rec/union/fn descent re-explores the shared child
-- twice per level — O(2^n), >120s at depth 30. With memoization it is linear.
-- This is the adversarial DAG shape the audit's perf wall exercised.
--: (integer, Ty) -> Ty
local function dag(n, leaf)
	local t = leaf
	for _ = 1, n do
		t = G.rec({ fld("a", t), fld("b", t) }, "closed")
	end
	return t
end

-- WIDE intersection: an intersection of `n` distinct open records (each adds a
-- field), the worst case for the record-conjunction decomposition.
--: (integer) -> Ty
local function wide_inter_records(n)
	local ms = {} --[[: { [integer]: Ty } ]]
	for i = 1, n do
		local key = "f" .. tostring(i)
		ms[#ms + 1] = G.rec({ fld(key, G.integer()) }, "open")
	end
	return G.inter(ms)
end

-- ── Timing harness ───────────────────────────────────────────────────────────

--: (() -> unknown, integer) -> number
local function time_ms(thunk, iters)
	local t0 = os.clock()
	for _ = 1, iters do thunk() end
	local t1 = os.clock()
	return (t1 - t0) * 1000.0
end

--: (string, () -> unknown, integer) -> nil
local function bench(name, thunk, iters)
	-- warm the interner / JIT.
	thunk()
	local ms = time_ms(thunk, iters)
	local per = ms / iters
	print(string.format("  %-44s %8d iters  %9.3f ms total  %8.5f ms/query",
		name, iters, ms, per))
end

print("slice_subtype benchmark (§5.1) — LuaJIT " .. (jit and jit.version or "?"))
print("")

-- Build the adversarial types once (interning is part of setup, not the query).
local H = hamt()
local H_unfold = G.unfold(H)
local Interior = G.rec({ fld("kind", G.integer()), fld("children", G.indexer(G.integer(), H)) }, "closed")

local DM   = deep_mu(40)
local DM2  = deep_mu(40)   -- structurally identical → same tid (interned)
local DMu  = G.unfold(DM)

local WU   = wide_union(200)
local WU2  = wide_union(200)
local WUbig = wide_union(400)

local WI   = wide_inter_records(60)
local WI2  = wide_inter_records(60)

print("setup: hamt, deep_mu(40), wide_union(200/400), wide_inter_records(60) interned")
print("")
print("query benchmarks (each is one is_subtype call per iteration):")

bench("hamt <: hamt (reflexive, interned)",        function() return S.is_subtype(H, H) end,            100000)
bench("hamt <: unfold(hamt)",                      function() return S.is_subtype(H, H_unfold) end,     100000)
bench("Interior(hamt) <: hamt (coinductive)",      function() return S.is_subtype(Interior, H) end,     100000)
bench("deep_mu(40) <: deep_mu(40) (interned refl)", function() return S.is_subtype(DM, DM2) end,        100000)
bench("deep_mu(40) <: unfold(deep_mu(40))",        function() return S.is_subtype(DM, DMu) end,         20000)
bench("wide_union(200) <: wide_union(200)",        function() return S.is_subtype(WU, WU2) end,         20000)
bench("wide_union(200) <: wide_union(400)",        function() return S.is_subtype(WU, WUbig) end,       20000)
local L150 = G.lit_int(150)
bench("lit_int(150) <: wide_union(200)",           function() return S.is_subtype(L150, WU) end,        20000)
local F1rec = G.rec({ fld("f1", G.integer()) }, "open")
bench("wide_inter_records(60) <: f1-record",       function() return S.is_subtype(WI, F1rec) end,       20000)
bench("wide_inter_records(60) <: wide_inter(60)",  function() return S.is_subtype(WI, WI2) end,         20000)

-- Shared-subterm DAG (finding 4): the perf-wall shape. Pre-memoization this was
-- O(2^n) — >120s at depth 30; post-memoization it is linear in the DAG size.
local DAG30a = dag(30, G.lit_int(1))
local DAG30b = dag(30, G.integer())
bench("dag(30) lit_int(1) <: dag(30) integer",     function() return S.is_subtype(DAG30a, DAG30b) end,  20000)
local DAG40a = dag(40, G.lit_int(1))
local DAG40b = dag(40, G.integer())
bench("dag(40) lit_int(1) <: dag(40) integer",     function() return S.is_subtype(DAG40a, DAG40b) end,  20000)

print("")
-- Worst single-query latency probe: time ONE query of the heaviest shape and
-- assert it is nowhere near the timeout-30 ceiling.
--: () -> boolean
local heavy = function() return S.is_subtype(DM, DMu) end
heavy()
local single = time_ms(heavy, 1)
print(string.format("heaviest single query (deep_mu unfold): %.5f ms  (ceiling: 30000 ms)", single))
print(string.format("headroom factor vs timeout-30: %.0fx", 30000.0 / math.max(single, 1e-6)))
