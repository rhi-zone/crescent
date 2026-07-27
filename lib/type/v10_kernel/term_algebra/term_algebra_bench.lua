-- lib/type/v10_kernel/term_algebra/term_algebra_bench.lua
--
-- Benchmark harness comparing the reference and fast tiers on representative
-- inputs: build, equal, shift, and subst over a deep, right-nested term with
-- shared substructure (the case interning and lazy subst are meant to help),
-- plus a repeated-subst chain (the case lazy subst is specifically meant to
-- help — each step in the reference tier eagerly rebuilds the whole
-- remaining term; the fast tier only allocates a thunk per step, forcing
-- only when the fast-tier result is itself inspected). Not a test; run via
-- `bin/cr run lib/type/v10_kernel/term_algebra/term_algebra_bench.lua`.
-- Results recorded in docs/perf/log.md per repo perf-work convention.
--
-- TYPECHECKER WORKAROUND (see TODO.md for the full repro): a kernel
-- instance's precise inferred type collapses to opaque `unknown` on direct
-- member access at top-level (module chunk) scope — confirmed fixed by
-- wrapping in a function — and, isolated further by bisection, ALSO
-- collapses the moment the enclosing function carries an explicit `--:`
-- return-type annotation (even an unrelated one, e.g. `() -> nil`, naming
-- nothing about the kernel instance at all). Every benchmark case below is
-- therefore a plain `local function bench_x() ... end` with NO signature
-- annotation (accepting the resulting "no signature" warning) — each still
-- extracts the specific methods it needs into locals immediately after
-- `kernel.new`, before any other use of the instance, matching the same
-- extract-then-pass discipline as the parity test's workaround.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local bench = require("lib.bench")
local kernel = require("lib.type.v10_kernel.term_algebra")

--: () -> number
local function clock_ns() return os.clock() * 1e9 end

local sig = kernel.declare_signature({
	name = "bench-theory", version = 1, sorts = { "term" },
	ops = {
		zero = { result = "term", args = {} },
		succ = { result = "term", args = { { sort = "term" } } },
		app = { result = "term", args = { { sort = "term" }, { sort = "term" } } },
		lam = { result = "term", args = { { sort = "term", binds = { "term" } } } },
	},
})

-- A right-nested chain of DEPTH `lam(app(var(0), succ( ... )))` layers,
-- deep enough to make per-node overhead (allocation, interning, context
-- merge) the dominant cost rather than fixed setup.
local DEPTH = 200

-- Takes already-extracted `build_var`/`build` functions (never the kernel
-- instance table itself — see the workaround note above) and returns a
-- deep, fully CLOSED term built through them (every var(0) is bound by its
-- own immediate lam — fine for build/equal/shift, which don't care whether
-- a term is closed).
--: (build_var_fn: (integer, string) -> (unknown | nil, string | nil), build_fn: (unknown, unknown[]) -> (unknown | nil, string | nil)) -> unknown
local function build_deep(build_var_fn, build_fn)
	local t, err = build_fn(sig.ops.zero, {})
	if not t then error("build_deep: " .. tostring(err)) end
	for _ = 1, DEPTH do
		local v0, verr = build_var_fn(0, "term")
		if not v0 then error("build_deep: " .. tostring(verr)) end
		local app_t, aerr = build_fn(sig.ops.app, { v0, t })
		if not app_t then error("build_deep: " .. tostring(aerr)) end
		local lam_t, lerr = build_fn(sig.ops.lam, { app_t })
		if not lam_t then error("build_deep: " .. tostring(lerr)) end
		t = lam_t
	end
	return t
end

-- Deep term with a GENUINELY FREE variable at index 0 (relative to the
-- whole term) reachable only by walking through all DEPTH binders —
-- required so the subst benchmarks exercise real substitution work in
-- both tiers, rather than the O(1) "index provably absent" short-circuit
-- every closed term (e.g. build_deep's) hits immediately regardless of
-- tier. At each wrap, the accumulated free-var reference is shifted by 1
-- to compensate for the newly-added binder — this is what keeps it
-- pointing at "the same" free variable, now one level further out (the
-- discharge arithmetic in `build` confirms this: an index shifted by
-- exactly the introduced binder count re-lands at the same outer index).
--: (build_var_fn: (integer, string) -> (unknown | nil, string | nil), build_fn: (unknown, unknown[]) -> (unknown | nil, string | nil), shift_fn: (unknown, integer, integer) -> (unknown | nil, string | nil)) -> unknown
local function build_deep_with_free_var(build_var_fn, build_fn, shift_fn)
	local t, verr = build_var_fn(0, "term")
	if not t then error("build_deep_with_free_var: " .. tostring(verr)) end
	for _ = 1, DEPTH do
		local shifted_t, serr = shift_fn(t, 1, 0)
		if not shifted_t then error("build_deep_with_free_var: " .. tostring(serr)) end
		local zero_t, zerr = build_fn(sig.ops.zero, {})
		if not zero_t then error("build_deep_with_free_var: " .. tostring(zerr)) end
		local app_t, aerr = build_fn(sig.ops.app, { shifted_t, zero_t })
		if not app_t then error("build_deep_with_free_var: " .. tostring(aerr)) end
		local lam_t, lerr = build_fn(sig.ops.lam, { app_t })
		if not lam_t then error("build_deep_with_free_var: " .. tostring(lerr)) end
		t = lam_t
	end
	return t
end

local TIERS = { "reference", "fast" }
local OPTS = { duration = 0.5, warmup = 0.05 }
local RUN_OPTS = { duration = OPTS.duration, warmup = OPTS.warmup, clock_fn = clock_ns }
local CHAIN_LEN = 50

-- ── build ────────────────────────────────────────────────────────────────

local function bench_build()
	local s = bench.suite("build (construct the DEPTH-deep term from scratch)")
	for _, tier in ipairs(TIERS) do
		local k = kernel.new({ tier = tier })
		local build_var_fn = k.build_var
		local build_fn = k.build
		s:add(tier, function() build_deep(build_var_fn, build_fn) end)
	end
	s:print(s:run(RUN_OPTS))
	io.write("\n")
end

-- ── equal (self-equal, common case) ─────────────────────────────────────

local function bench_equal_self()
	local s = bench.suite("equal (t == t, same object)")
	for _, tier in ipairs(TIERS) do
		local k = kernel.new({ tier = tier })
		local build_var_fn = k.build_var
		local build_fn = k.build
		local equal_fn = k.equal
		local t = build_deep(build_var_fn, build_fn)
		s:add(tier, function() equal_fn(t, t) end)
	end
	s:print(s:run(RUN_OPTS))
	io.write("\n")
end

-- ── equal (structurally-equal, freshly rebuilt second copy) ─────────────

local function bench_equal_structural()
	local s = bench.suite("equal (structurally-equal but independently-built copy)")
	for _, tier in ipairs(TIERS) do
		local k = kernel.new({ tier = tier })
		local build_var_fn = k.build_var
		local build_fn = k.build
		local equal_fn = k.equal
		local t1 = build_deep(build_var_fn, build_fn)
		local t2 = build_deep(build_var_fn, build_fn)
		s:add(tier, function() equal_fn(t1, t2) end)
	end
	s:print(s:run(RUN_OPTS))
	io.write("\n")
end

-- ── shift ────────────────────────────────────────────────────────────────

local function bench_shift()
	local s = bench.suite("shift (whole term, d=1, cutoff=0)")
	for _, tier in ipairs(TIERS) do
		local k = kernel.new({ tier = tier })
		local build_var_fn = k.build_var
		local build_fn = k.build
		local shift_fn = k.shift
		local t = build_deep(build_var_fn, build_fn)
		s:add(tier, function() shift_fn(t, 1, 0) end)
	end
	s:print(s:run(RUN_OPTS))
	io.write("\n")
end

-- ── subst (single application, result never forced) ──────────────────────

local function bench_subst_single()
	local s = bench.suite("subst (single application, real work — replaces the one free var; fast tier's result left unforced)")
	for _, tier in ipairs(TIERS) do
		local k = kernel.new({ tier = tier })
		local build_var_fn = k.build_var
		local build_fn = k.build
		local shift_fn = k.shift
		local subst_fn = k.subst
		local t = build_deep_with_free_var(build_var_fn, build_fn, shift_fn)
		local u = build_fn(sig.ops.zero, {})
		s:add(tier, function() subst_fn(t, 0, u) end)
	end
	s:print(s:run(RUN_OPTS))
	io.write("\n")
end

-- ── subst chain (repeated substitution, never forcing intermediate results
-- until the very end — the case lazy subst is specifically meant to help:
-- the reference tier eagerly rebuilds the whole remaining term at every
-- step; the fast tier only allocates a thunk per step). A flat chain of
-- CHAIN_LEN SIMULTANEOUSLY free variables (var(0)..var(CHAIN_LEN-1), no
-- binder anywhere — `app(var(0), app(var(1), ... app(var(CHAIN_LEN-1),
-- zero)))`) substituted one at a time, in order, so every step does real
-- work (replaces a var that is genuinely still free in the current term),
-- not the O(1) short-circuit. ─────────────────────────────────────────────

-- Takes already-extracted `build_var`/`build` functions and returns a flat
-- chain of CHAIN_LEN simultaneously-free variables.
--: (build_var_fn: (integer, string) -> (unknown | nil, string | nil), build_fn: (unknown, unknown[]) -> (unknown | nil, string | nil)) -> unknown
local function build_flat_chain(build_var_fn, build_fn)
	local t, zerr = build_fn(sig.ops.zero, {})
	if not t then error("build_flat_chain: " .. tostring(zerr)) end
	for i = CHAIN_LEN - 1, 0, -1 do
		local vi, verr = build_var_fn(i, "term")
		if not vi then error("build_flat_chain: " .. tostring(verr)) end
		local app_t, aerr = build_fn(sig.ops.app, { vi, t })
		if not app_t then error("build_flat_chain: " .. tostring(aerr)) end
		t = app_t
	end
	return t
end

local function bench_subst_chain()
	local s = bench.suite(string.format("subst chain (%d steps, real work per step, force only at the end)", CHAIN_LEN))
	for _, tier in ipairs(TIERS) do
		local k = kernel.new({ tier = tier })
		local build_var_fn = k.build_var
		local build_fn = k.build
		local subst_fn = k.subst
		local sort_of_fn = k.sort_of
		local shift_fn = k.shift
		local t0 = build_flat_chain(build_var_fn, build_fn)
		local u = build_fn(sig.ops.zero, {})
		s:add(tier, function()
			local t = t0
			for i = 0, CHAIN_LEN - 1 do
				local next_t, err = subst_fn(t, i, u)
				if not next_t then error("subst chain failed at step " .. i .. ": " .. tostring(err)) end
				t = next_t
			end
			-- Force the final result once, so the fast tier actually pays
			-- for the deferred work exactly once per chain (like a real
			-- caller inspecting the end result), same as the reference
			-- tier's already-eager result.
			sort_of_fn(t)
			shift_fn(t, 0, 0)
		end)
	end
	s:print(s:run(RUN_OPTS))
	io.write("\n")
end

io.write(string.format("v10 kernel term algebra bench — DEPTH=%d, duration=%.1fs per case\n\n", DEPTH, OPTS.duration))
bench_build()
bench_equal_self()
bench_equal_structural()
bench_shift()
bench_subst_single()
bench_subst_chain()

return {}
