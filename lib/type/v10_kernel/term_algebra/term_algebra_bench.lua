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
--: (build_var_fn: (integer, unknown) -> (unknown | nil, string | nil), build_fn: (unknown, unknown[]) -> (unknown | nil, string | nil)) -> unknown
local function build_deep(build_var_fn, build_fn)
	local t, err = build_fn(sig.ops.zero, {})
	if not t then error("build_deep: " .. tostring(err)) end
	for _ = 1, DEPTH do
		local v0, verr = build_var_fn(0, sig.sorts.term)
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
--: (build_var_fn: (integer, unknown) -> (unknown | nil, string | nil), build_fn: (unknown, unknown[]) -> (unknown | nil, string | nil), shift_fn: (unknown, integer, integer) -> (unknown | nil, string | nil)) -> unknown
local function build_deep_with_free_var(build_var_fn, build_fn, shift_fn)
	local t, verr = build_var_fn(0, sig.sorts.term)
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

-- ── subst chain — ADVERSARIAL DEEP-INSPECT CASE, NOT A REPLAY WORKLOAD ─────
--
-- RELABELED 2026-07-28: this benchmark's own access pattern was originally
-- read as "the case lazy subst is specifically meant to help." A
-- design-level review (docs/decisions/typechecker-v10-core-design.md's
-- replay hot path: match walks a rule-sized pattern without entering
-- captured subterms, instantiate pastes shared references, groundness/
-- closedness/sort are O(1) cached, intern hashing is incremental) confirmed
-- that replay itself never does what THIS benchmark does: build a flat
-- chain where `var(i)` sits exactly `i` levels deep, then substitute
-- `var(0)`, `var(1)`, ..., `var(CHAIN_LEN-1)` in order — the target index at
-- step `i` is only findable by walking `i` levels into the (evolving) term,
-- so BOTH tiers pay O(i) work locating/handling it, making the whole chain
-- O(CHAIN_LEN²) in EITHER tier; the fast tier's per-node interning
-- constant factor then dominates. This is a genuine, real, measured
-- fast-tier weakness (see docs/perf/log.md) — kept here deliberately as the
-- adversarial stress case, NOT deleted — but see `bench_compose_then_match`
-- below for the actual replay-shaped equivalent (unobserved composition
-- ending in ONE rule-sized match, not depth-ordered substitution ending in
-- a full force). Do not read this benchmark's slowdown as "the kernel is
-- 10x slower," per the same doc review — see the replay-shaped benches for
-- what the kernel's own hot path measures as.
--
-- A flat chain of CHAIN_LEN SIMULTANEOUSLY free variables
-- (var(0)..var(CHAIN_LEN-1), no binder anywhere — `app(var(0),
-- app(var(1), ... app(var(CHAIN_LEN-1), zero)))`) substituted one at a
-- time, in order, so every step does real work (replaces a var that is
-- genuinely still free in the current term), not the O(1) short-circuit.
-- ────────────────────────────────────────────────────────────────────────

-- Takes already-extracted `build_var`/`build` functions and returns a flat
-- chain of CHAIN_LEN simultaneously-free variables.
--: (build_var_fn: (integer, unknown) -> (unknown | nil, string | nil), build_fn: (unknown, unknown[]) -> (unknown | nil, string | nil)) -> unknown
local function build_flat_chain(build_var_fn, build_fn)
	local t, zerr = build_fn(sig.ops.zero, {})
	if not t then error("build_flat_chain: " .. tostring(zerr)) end
	for i = CHAIN_LEN - 1, 0, -1 do
		local vi, verr = build_var_fn(i, sig.sorts.term)
		if not vi then error("build_flat_chain: " .. tostring(verr)) end
		local app_t, aerr = build_fn(sig.ops.app, { vi, t })
		if not app_t then error("build_flat_chain: " .. tostring(aerr)) end
		t = app_t
	end
	return t
end

local function bench_subst_chain()
	local s = bench.suite(string.format(
		"ADVERSARIAL (not replay-shaped): subst chain, depth-ordered (%d steps, O(i) walk per step, force only at the end)",
		CHAIN_LEN))
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

-- ── REPLAY-SHAPED BENCHMARKS ─────────────────────────────────────────────
--
-- The three benchmarks below model what docs/decisions/typechecker-v10-
-- core-design.md's replay hot path actually does, per the 2026-07-28
-- design review recorded in docs/perf/log.md: match walks a rule-sized
-- pattern (never the whole subject term), captures metavariable subterms
-- as shared references WITHOUT entering them, instantiate pastes those
-- shared references while walking the (also rule-sized) conclusion
-- pattern, and non-linear/binding-depth checks reduce to pointer equality
-- on the interned tier. None of these workloads deep-inspect a term after
-- composing it — the adversarial `bench_subst_chain` above does exactly
-- that, deliberately, and is kept as the stress case, not as a replay
-- proxy.

-- A single rule-sized pattern used by both replay-shaped benches below:
-- `app(A, B)` — two metavariables, sort "term", arity matching `app`'s
-- declared valence. Building it once per tier (outside any timed closure)
-- mirrors how a real replay run declares a rule's patterns once and reuses
-- them across every citing derivation node, not once per citation.
--: (build_meta_fn: (string, unknown) -> (unknown | nil, string | nil), build_fn: (unknown, unknown[]) -> (unknown | nil, string | nil)) -> unknown
local function build_pattern_app_a_b(build_meta_fn, build_fn)
	local a, aerr = build_meta_fn("A", sig.sorts.term)
	if not a then error("build_pattern_app_a_b: " .. tostring(aerr)) end
	local b, berr = build_meta_fn("B", sig.sorts.term)
	if not b then error("build_pattern_app_a_b: " .. tostring(berr)) end
	local pat, perr = build_fn(sig.ops.app, { a, b })
	if not pat then error("build_pattern_app_a_b: " .. tostring(perr)) end
	return pat
end

-- ── compose-then-match (replay-shaped counterpart to the adversarial
-- subst chain above): the SAME CHAIN_LEN unobserved substitutions,
-- composed one at a time without ever inspecting an intermediate result —
-- but instead of ending in a full force (sort_of + shift(0,0), walking the
-- ENTIRE result), ends in ONE `match(app(A, B), t)` call: a rule-sized
-- pattern that only ever inspects the composed term's top op node plus
-- whatever its two immediate children force-head to, never the whole
-- CHAIN_LEN-deep structure. This is the actual shape replay composes-then-
-- cites in: build up a term (however it's built), then match a small rule
-- pattern against it once. ──────────────────────────────────────────────

local function bench_compose_then_match()
	local s = bench.suite(string.format(
		"REPLAY-SHAPED: compose-then-match (%d unobserved substitutions, ONE rule-sized match(app(A,B)) at the end)",
		CHAIN_LEN))
	for _, tier in ipairs(TIERS) do
		local k = kernel.new({ tier = tier })
		local build_var_fn = k.build_var
		local build_fn = k.build
		local build_meta_fn = k.build_meta
		local subst_fn = k.subst
		local match_fn = k.match
		local t0 = build_flat_chain(build_var_fn, build_fn)
		local u = build_fn(sig.ops.zero, {})
		local pattern = build_pattern_app_a_b(build_meta_fn, build_fn)
		s:add(tier, function()
			local t = t0
			for i = 0, CHAIN_LEN - 1 do
				local next_t, err = subst_fn(t, i, u)
				if not next_t then error("compose-then-match: subst failed at step " .. i .. ": " .. tostring(err)) end
				t = next_t
			end
			local bindings, merr = match_fn(pattern, t)
			if not bindings then error("compose-then-match: match failed: " .. tostring(merr)) end
		end)
	end
	s:print(s:run(RUN_OPTS))
	io.write("\n")
end

-- ── instantiate-heavy (many small rule applications over a growing,
-- shared fact chain): RULE_STEPS independent steps, each building one
-- small candidate term, matching the SAME small premise pattern
-- `app(A, B)` against it, then instantiating the SAME small conclusion
-- pattern `app(B, A)` (argument swap) from the resulting bindings — the
-- instantiated conclusion becomes part of the next step's candidate, so
-- the term DAG grows by one node per step while every step's own match/
-- instantiate work stays rule-sized (bounded by the 2-metavariable
-- pattern, never by how large the accumulated fact chain has grown).
-- Representative of forward-chaining a derivation: many small rule
-- applications, not one big substitution. ─────────────────────────────────

local RULE_STEPS = 200

local function bench_instantiate_heavy()
	local s = bench.suite(string.format(
		"REPLAY-SHAPED: instantiate-heavy (%d small rule applications — match(app(A,B)) then instantiate(app(B,A)) — over a growing shared fact chain)",
		RULE_STEPS))
	for _, tier in ipairs(TIERS) do
		local k = kernel.new({ tier = tier })
		local build_var_fn = k.build_var
		local build_fn = k.build
		local build_meta_fn = k.build_meta
		local match_fn = k.match
		local instantiate_fn = k.instantiate
		local premise = build_pattern_app_a_b(build_meta_fn, build_fn)
		local concl_b, cberr = build_meta_fn("B", sig.sorts.term)
		if not concl_b then error("bench_instantiate_heavy: " .. tostring(cberr)) end
		local concl_a, caerr = build_meta_fn("A", sig.sorts.term)
		if not concl_a then error("bench_instantiate_heavy: " .. tostring(caerr)) end
		local conclusion, coerr = build_fn(sig.ops.app, { concl_b, concl_a })
		if not conclusion then error("bench_instantiate_heavy: " .. tostring(coerr)) end
		local zero0, zerr = build_fn(sig.ops.zero, {})
		if not zero0 then error("bench_instantiate_heavy: " .. tostring(zerr)) end
		s:add(tier, function()
			local fact = zero0
			for i = 0, RULE_STEPS - 1 do
				local vi, verr = build_var_fn(i, sig.sorts.term)
				if not vi then error("bench_instantiate_heavy: build_var failed at step " .. i .. ": " .. tostring(verr)) end
				local candidate, cerr = build_fn(sig.ops.app, { vi, fact })
				if not candidate then error("bench_instantiate_heavy: build failed at step " .. i .. ": " .. tostring(cerr)) end
				local bindings, merr = match_fn(premise, candidate)
				if not bindings then error("bench_instantiate_heavy: match failed at step " .. i .. ": " .. tostring(merr)) end
				local concluded, ierr = instantiate_fn(conclusion, bindings)
				if not concluded then error("bench_instantiate_heavy: instantiate failed at step " .. i .. ": " .. tostring(ierr)) end
				fact = concluded
			end
		end)
	end
	s:print(s:run(RUN_OPTS))
	io.write("\n")
end

-- ── equal citation-check (repeated equal on a large, growing, shared
-- structure): builds CITATION_FACTS facts, each wrapping the previous
-- (`app(var(i mod 7), fact_{i-1})`, reusing a small handful of variable
-- indices the way a real derivation reuses a handful of local binders) so
-- every fact shares almost all of its structure with its predecessor —
-- then, for each fact, checks `equal` against every OTHER already-built
-- fact (an O(n²) citation scan: "has this exact judgment already been
-- derived?", a real replay operation over an accumulating fact set).
-- Facts are built ONCE outside the timed closure (both tiers see the same
-- fixed pool); only the equality scan itself is timed. ───────────────────

local CITATION_FACTS = 100

--: (build_var_fn: (integer, unknown) -> (unknown | nil, string | nil), build_fn: (unknown, unknown[]) -> (unknown | nil, string | nil)) -> unknown
local function build_citation_facts(build_var_fn, build_fn)
	local facts = {} --[[: { [integer]: unknown } ]]
	local fact, zerr = build_fn(sig.ops.zero, {})
	if not fact then error("build_citation_facts: " .. tostring(zerr)) end
	for i = 1, CITATION_FACTS do
		local vi, verr = build_var_fn(i % 7, sig.sorts.term)
		if not vi then error("build_citation_facts: " .. tostring(verr)) end
		local next_fact, ferr = build_fn(sig.ops.app, { vi, fact })
		if not next_fact then error("build_citation_facts: " .. tostring(ferr)) end
		fact = next_fact
		facts[i] = fact
	end
	return facts
end

local function bench_equal_citation()
	local s = bench.suite(string.format(
		"REPLAY-SHAPED: equal citation-check (%d growing shared facts, pairwise equal against all previously-seen facts)",
		CITATION_FACTS))
	for _, tier in ipairs(TIERS) do
		local k = kernel.new({ tier = tier })
		local build_var_fn = k.build_var
		local build_fn = k.build
		local equal_fn = k.equal
		local facts = build_citation_facts(build_var_fn, build_fn)
		s:add(tier, function()
			for i = 1, CITATION_FACTS do
				for j = 1, i - 1 do
					equal_fn(facts[i], facts[j])
				end
			end
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
bench_compose_then_match()
bench_instantiate_heavy()
bench_equal_citation()

return {}
