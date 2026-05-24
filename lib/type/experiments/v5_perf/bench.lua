-- lib/type/experiments/v5_perf/bench.lua
-- Falsifiability gate: run solver on synthetic corpus and report
-- wall time, live heap at quiescence, and reactivations/emissions ratio.
--
-- Gates (per v5 perf-attacker round 2):
--   wall time            : <500ms per file (median of 5)
--   live heap at quiescence : <2 MB
--   reactivations/emissions : <5x ratio
--
-- Invoke: bin/cr run lib/type/experiments/v5_perf/bench.lua [corpus-files...]
-- Defaults to the two reference corpus files.

-- Ordered requires: each module that defines a `--::` alias must be required
-- before any consumer references that alias in its signatures.
local _types         = require("lib.type.experiments.v5_perf.types")
local _subst         = require("lib.type.experiments.v5_perf.subst")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")
local solver_mod     = require("lib.type.experiments.v5_perf.solver")
local corpus_mod     = require("lib.type.experiments.v5_perf.corpus_extract")
local _ = _types; local _2 = _subst

local M = {}

local DEFAULT_FILES = {
	"lib/test/arb.lua",        -- substitute for lib/test/init.lua (does not exist in repo)
	"lib/stdlib/lint.lua",     -- substitute for lib/std/init.lua (does not exist in repo)
}

local RUNS = 5

--:: RunResult = { wall_ms: number, heap_kb: number, emissions: integer, reactivations: integer, popped: integer, inert_remaining: integer, errors: integer, constraint_count: integer }

-- Measure live heap by forcing a full collection, then reading the count
-- (returns KB).  Call between runs to isolate live state from churn.
--: () -> number
local function live_heap_kb()
	collectgarbage("collect")
	collectgarbage("collect")
	local kb = collectgarbage("count")
	if type(kb) ~= "number" then return 0 end
	return kb
end

-- Reorder constraints so that method_call and table_seal precede
-- table_set/table_open for the same receiver, forcing the scheduler to
-- park constraints in the inert set and wake them once table_sets fire.
-- This is the WORST case for the architecture — naturally-ordered streams
-- (gen-pass output) produce ~0 reactivations because forward refs are rare.
--: (V5Constraint[]) -> V5Constraint[]
local function stress_reorder(constraints)
	local consumers = {} --[[: V5Constraint[] ]]
	local producers = {} --[[: V5Constraint[] ]]
	local mc, pc = 0, 0
	for i = 1, #constraints do
		local c = constraints[i]
		if c ~= nil then
			if c.tag == "mcall" or c.tag == "tseal" then
				mc = mc + 1; consumers[mc] = c
			else
				pc = pc + 1; producers[pc] = c
			end
		end
	end
	local out = {} --[[: V5Constraint[] ]]
	local oi = 0
	for i = 1, #consumers do oi = oi + 1; out[oi] = consumers[i] end
	for i = 1, #producers do oi = oi + 1; out[oi] = producers[i] end
	return out
end

--: (V5Constraint[]) -> RunResult
local function one_run(constraints)
	-- Reset state before measuring
	constraint_mod.reset_ids()
	collectgarbage("stop")
	local heap_before = live_heap_kb()
	local t0 = os.clock()
	local s = solver_mod.new()
	for i = 1, #constraints do
		local c = constraints[i]
		if c ~= nil then solver_mod.emit(s, c) end
	end
	solver_mod.solve(s)
	local t1 = os.clock()
	local heap_after = live_heap_kb()
	-- Count remaining inert
	local inert_n = 0
	for _ in pairs(s.inert) do inert_n = inert_n + 1 end
	collectgarbage("restart")
	return {
		wall_ms = (t1 - t0) * 1000,
		heap_kb = heap_after - heap_before,
		emissions = s.stats.emissions,
		reactivations = s.stats.reactivations,
		popped = s.stats.popped,
		inert_remaining = inert_n,
		errors = #s.stats.errors,
		constraint_count = #constraints,
	}
end

--: (RunResult[], (RunResult) -> number) -> number
local function median(results, getter)
	local xs = {} --[[: { [integer]: number } ]]
	local m = 0
	for i = 1, #results do
		local r = results[i]
		if r ~= nil then m = m + 1; xs[m] = getter(r) end
	end
	table.sort(xs)
	local n = #xs
	if n == 0 then return 0 end
	if n % 2 == 1 then
		local mid = xs[math.floor((n + 1) / 2)]
		return mid or 0
	end
	local a = xs[math.floor(n / 2)]
	local b = xs[math.floor(n / 2) + 1]
	if a == nil or b == nil then return 0 end
	return (a + b) / 2
end

--: (string, V5Constraint[], string) -> nil
local function run_and_report(file, constraints, label)
	io.write("--- " .. label .. " ---\n")
	one_run(constraints) -- JIT warm-up
	local results = {} --[[: RunResult[] ]]
	for i = 1, RUNS do
		results[i] = one_run(constraints)
		local r = results[i]
		if r ~= nil then
			io.write(string.format("  run %d: wall=%.2fms heap=%.1fKB emit=%d react=%d pop=%d inert=%d err=%d\n",
				i, r.wall_ms, r.heap_kb, r.emissions, r.reactivations,
				r.popped, r.inert_remaining, r.errors))
		end
	end

	local m_wall  = median(results, function(r) return r.wall_ms end)
	local m_heap  = median(results, function(r) return r.heap_kb end)
	local m_emit  = median(results, function(r) return r.emissions end)
	local m_react = median(results, function(r) return r.reactivations end)
	local ratio = m_emit > 0 and (m_react / m_emit) or 0

	io.write(string.format("MEDIAN(%s): wall=%.2fms heap=%.1fKB emit=%d react=%d ratio=%.3f\n",
		label, m_wall, m_heap, m_emit, m_react, ratio))

	local pass_wall  = m_wall < 500
	local pass_heap  = m_heap < 2048
	local pass_ratio = ratio < 5
	io.write(string.format("GATES(%s): wall<500ms=%s heap<2MB=%s ratio<5x=%s -- %s\n",
		label, tostring(pass_wall), tostring(pass_heap), tostring(pass_ratio),
		(pass_wall and pass_heap and pass_ratio) and "PASS" or "FAIL"))
	-- Discard locals not needed
	local _ = file
end

--: (string) -> nil
function M.bench_file(file)
	io.write("\n=== " .. file .. " ===\n")
	local extracted = corpus_mod.extract(file)
	local constraints = extracted.constraints
	io.write(string.format("constraints extracted: %d (tvars touched: %d)\n",
		#constraints, extracted.tvar_counter))
	run_and_report(file, constraints, "natural-order")
	local stress = stress_reorder(constraints)
	run_and_report(file, stress, "stress-consumers-first")
end

--: (string[]) -> nil
function M.main(argv)
	local files = argv
	if files == nil or #files == 0 then files = DEFAULT_FILES end
	io.write("v5 perf bench (5 runs/file, FIFO worklist, FFI=no)\n")
	for i = 1, #files do
		local f = files[i]
		if f ~= nil then M.bench_file(f) end
	end
end

return M
