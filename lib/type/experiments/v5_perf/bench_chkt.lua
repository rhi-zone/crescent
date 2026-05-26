-- lib/type/experiments/v5_perf/bench_chkt.lua
-- Falsifiability re-gate after the CHKT + HOUnify constraint family.
--
-- Runs op_sem (lib/type/static-v5/op_sem.lua) on a synthetic corpus that
-- mixes the previously-shipped constraint families with new CHKT and
-- HOUnify ones, derived per-file from real Lua source.  Reports wall
-- time, live heap, and reactivations/emissions ratio, per the three
-- gates (<500ms, <2MB, <5x).  Per the v5 re-gate schedule.
--
-- Invoke: bin/cr run lib/type/experiments/v5_perf/bench_chkt.lua [files...]
-- Defaults to the same reference corpus as bench.lua.

local types_mod      = require("lib.type.experiments.v5_perf.types")
local subst_mod      = require("lib.type.experiments.v5_perf.subst")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")
local corpus_mod     = require("lib.type.experiments.v5_perf.corpus_extract")
local op_sem         = require("lib.type.static-v5.op_sem")
local _ = subst_mod; local _2 = types_mod

local M = {}

local DEFAULT_FILES = {
	"lib/test/arb.lua",
	"lib/stdlib/lint.lua",
}

local RUNS = 5

--:: ChktBench = { wall_ms: number, heap_kb: number, emissions: integer, reactivations: integer, errors: integer, constraint_count: integer, chkt_count: integer }

-- Build a synthetic CHKT/HOUnify load.  For every k receivers seen in the
-- base corpus, synthesise (a) one CHKT(?F_k, [?a_k], ?r_k) in the Miller
-- fragment (binds ?F_k), and (b) one CHKT(?F'_k, [App(?G_k, int_const)],
-- ?r'_k) outside the fragment (parks as HOUnify, becomes T-HOUnify-Stuck).
-- Half of the (b) cases get a downstream CEq(?F'_k, maybe_lambda) that
-- rigidifies and wakes.  This produces a realistic mix of reduce/Miller/
-- park/wake/stuck dispatches.
--: (integer) -> { extra: OpSemConstraint[], chkt_count: integer }
local function synthesise_chkt(receivers_n)
	local extra = {} --[[: OpSemConstraint[] ]]
	local out_n = 0
	local count = 0
	local int_ty = types_mod.const("number") --[[: V5Type ]]
	local string_ty = types_mod.const("string") --[[: V5Type ]]
	local var0 = types_mod.var(0) --[[: V5Type ]]
	local maybe_body = types_mod.record({ tag = string_ty, val = var0 }) --[[: V5Type ]]
	local maybe_lambda = types_mod.lambda("*", maybe_body) --[[: V5Type ]]
	-- We can't allocate fresh tvars here without a subst; encode tvars
	-- as integer ids in a sequence that doesn't collide with the base
	-- corpus's tvars (base uses 1..N; we use a high base).  Since each
	-- bench run creates a fresh op_sem state and we emit constraints
	-- referring to those ids, we need the state's tvars allocated to
	-- match.  This is handled in one_run below.
	local _ = int_ty; local _3 = maybe_lambda
	return { extra = extra, chkt_count = count }
end
local _ = synthesise_chkt -- not used directly; see one_run below.

-- Heap measurement (KB after full GC).
--: () -> number
local function live_heap_kb()
	collectgarbage("collect"); collectgarbage("collect")
	local kb = collectgarbage("count")
	if type(kb) ~= "number" then return 0 end
	return kb
end

-- Run op_sem on a corpus.  Inside this run we allocate fresh tvars in
-- the op_sem state for the synthetic CHKT receivers.
--: (V5Constraint[], integer) -> ChktBench
local function one_run(base_constraints, receivers_n)
	constraint_mod.reset_ids()
	collectgarbage("stop")
	local heap_before = live_heap_kb()
	local t0 = os.clock()
	local st = op_sem.new_state()

	-- Emit base constraints.
	for i = 1, #base_constraints do
		local c = base_constraints[i]
		if c ~= nil then op_sem.emit(st, c) end
	end

	-- Synthesise CHKT/HOUnify load on fresh tvars allocated against st.
	local int_ty = types_mod.const("number") --[[: V5Type ]]
	local string_ty = types_mod.const("string") --[[: V5Type ]]
	local var0 = types_mod.var(0) --[[: V5Type ]]
	local maybe_body = types_mod.record({ tag = string_ty, val = var0 }) --[[: V5Type ]]
	local maybe_lambda = types_mod.lambda("*", maybe_body) --[[: V5Type ]]
	local chkt_count = 0
	-- col=0: bench_chkt generates fully synthetic constraints; there is no source position to thread.
	for k = 1, receivers_n do
		-- (a) Miller-pattern CHKT: bind ?F_k via identity-like shape.
		local f = subst_mod.fresh(st.subst, "open")
		local a = subst_mod.fresh(st.subst, "open")
		local uf = types_mod.uvar(f) --[[: V5Type ]]
		local ua = types_mod.uvar(a) --[[: V5Type ]]
		op_sem.emit(st, op_sem.chkt(uf, { ua }, ua,
			constraint_mod.prov("synth-chkt-miller", k, 0, "synthesized")))
		chkt_count = chkt_count + 1

		-- (b) Outside-Miller CHKT (App arg) → HOUnify.
		local f2 = subst_mod.fresh(st.subst, "open")
		local g = subst_mod.fresh(st.subst, "open")
		local r = subst_mod.fresh(st.subst, "open")
		local uf2 = types_mod.uvar(f2) --[[: V5Type ]]
		local ug = types_mod.uvar(g) --[[: V5Type ]]
		local ur = types_mod.uvar(r) --[[: V5Type ]]
		local app_arg = types_mod.app(ug, int_ty) --[[: V5Type ]]
		op_sem.emit(st, op_sem.chkt(uf2, { app_arg }, ur,
			constraint_mod.prov("synth-chkt-park", k, 0, "synthesized")))
		chkt_count = chkt_count + 1

		-- Half of the (b) cases get a rigidifying CEq later in worklist.
		if (k % 2) == 0 then
			op_sem.emit(st, constraint_mod.eq(uf2, maybe_lambda,
				constraint_mod.prov("synth-rigidify", k, 0, "synthesized")))
		end

		-- (c) Variance-respecting CSub load: an Arrow CSub + a record-width
		-- CSub.  Exercises T-CSub-Arrow + T-CSub-Const-Var + T-CSub-Record-
		-- Width + T-CSub-Refl per receiver — typical CSub shapes a real gen
		-- pass will emit.
		local fn_a = types_mod.arrow({ int_ty }, { int_ty }) --[[: V5Type ]]
		local fn_b = types_mod.arrow({ int_ty }, { int_ty }) --[[: V5Type ]]
		op_sem.emit(st, constraint_mod.sub(fn_a, fn_b,
			constraint_mod.prov("synth-csub-arrow", k, 0, "synthesized")))
		local rec_wide = types_mod.record({ x = int_ty, y = string_ty }) --[[: V5Type ]]
		local rec_narrow = types_mod.record({ x = int_ty }) --[[: V5Type ]]
		op_sem.emit(st, constraint_mod.sub(rec_wide, rec_narrow,
			constraint_mod.prov("synth-csub-record", k, 0, "synthesized")))
	end

	op_sem.run(st)
	local t1 = os.clock()
	local heap_after = live_heap_kb()
	collectgarbage("restart")
	-- Emissions: count steps as proxy (we don't track explicit emissions).
	return {
		wall_ms          = (t1 - t0) * 1000,
		heap_kb          = heap_after - heap_before,
		emissions        = st.steps,
		reactivations    = st.reactivations,
		errors           = op_sem.error_count(st),
		constraint_count = #base_constraints + chkt_count,
		chkt_count       = chkt_count,
	}
end

--: (ChktBench[], (ChktBench) -> number) -> number
local function median(results, getter)
	local xs = {} --[[: { [integer]: number } ]]; local m = 0
	for i = 1, #results do
		local r = results[i]
		if r ~= nil then m = m + 1; xs[m] = getter(r) end
	end
	table.sort(xs)
	local n = #xs
	if n == 0 then return 0 end
	if n % 2 == 1 then local v = xs[math.floor((n + 1) / 2)]; return v or 0 end
	local a = xs[math.floor(n / 2)]; local b = xs[math.floor(n / 2) + 1]
	if a == nil or b == nil then return 0 end
	return (a + b) / 2
end

--: (string) -> nil
function M.bench_file(file)
	io.write("\n=== " .. file .. " (CHKT+HOUnify re-gate) ===\n")
	local extracted = corpus_mod.extract(file)
	local base = extracted.constraints
	-- Receivers_n: scale synthetic CHKT load to constraint count / 20.
	local receivers_n = math.max(1, math.floor(#base / 20))
	io.write(string.format("base constraints: %d ; synth CHKT receivers: %d\n",
		#base, receivers_n))
	one_run(base, receivers_n) -- warm-up
	local results = {} --[[: ChktBench[] ]]
	for i = 1, RUNS do
		results[i] = one_run(base, receivers_n)
		local r = results[i]
		if r ~= nil then
			io.write(string.format("  run %d: wall=%.2fms heap=%.1fKB step=%d react=%d err=%d chkt=%d total=%d\n",
				i, r.wall_ms, r.heap_kb, r.emissions, r.reactivations,
				r.errors, r.chkt_count, r.constraint_count))
		end
	end
	local m_wall  = median(results, function(r) return r.wall_ms end)
	local m_heap  = median(results, function(r) return r.heap_kb end)
	local m_emit  = median(results, function(r) return r.emissions end)
	local m_react = median(results, function(r) return r.reactivations end)
	local ratio = m_emit > 0 and (m_react / m_emit) or 0
	io.write(string.format("MEDIAN: wall=%.2fms heap=%.1fKB step=%d react=%d ratio=%.3f\n",
		m_wall, m_heap, m_emit, m_react, ratio))
	local p_wall = m_wall < 500
	local p_heap = m_heap < 2048
	local p_ratio = ratio < 5
	io.write(string.format("GATES: wall<500ms=%s heap<2MB=%s ratio<5x=%s -- %s\n",
		tostring(p_wall), tostring(p_heap), tostring(p_ratio),
		(p_wall and p_heap and p_ratio) and "PASS" or "FAIL"))
end

--: (string[]) -> nil
function M.main(argv)
	local files = argv
	if files == nil or #files == 0 then files = DEFAULT_FILES end
	io.write("v5 CHKT+HOUnify re-gate (5 runs/file, op_sem solver)\n")
	for i = 1, #files do
		local f = files[i]
		if f ~= nil then M.bench_file(f) end
	end
end

return M
