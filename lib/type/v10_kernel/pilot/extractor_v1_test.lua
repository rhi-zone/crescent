-- lib/type/v10_kernel/pilot/extractor_v1_test.lua
--
-- Phase 2 (AST→base-facts extractor). Every case drives the FULL path the
-- extractor exists for: parse real Lua source -> seed base facts into an
-- engine store -> run the engine over already-declared theory rules -> export
-- a derived fact as a kernel CertNode -> replay it against the REAL kernel
-- replayer, root-strict. A test that only counted seeded facts would prove
-- nothing about whether those facts are citable; replay is the check.
--
-- The narrowing vocabulary used throughout is `flow_narrow_v1`'s
-- (`narrow-pilot-v1` v2). `fixpoint_v1`'s v4 signature declares axioms and
-- rules under the SAME (name, version) keys, so the two cannot be declared
-- into one registry (F11) — a driver picks exactly one. Recorded here because
-- it is a real constraint on any driver, not an incidental test choice.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local engine = require("lib.type.v10_kernel.pilot.engine")
local extractor = require("lib.type.v10_kernel.pilot.extractor_v1")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local flow_narrow_v1 = require("lib.type.v10_kernel.pilot.flow_narrow_v1")
local pilot_initial_facts_v1 = require("lib.type.v10_kernel.pilot.pilot_initial_facts_v1")
local effects_spine_v1 = require("lib.type.v10_kernel.pilot.effects_spine_v1")
local assign_effects_v1 = require("lib.type.v10_kernel.pilot.assign_effects_v1")
local narrow_persist_v1 = require("lib.type.v10_kernel.pilot.narrow_persist_v1")

-- One `must_*` per result type: a single generic `must` would return
-- `unknown`, and `unknown` must be NARROWED, never cast, at the use site
-- (same shape as engine_test.lua's own helper set).
--: (v: Signature | nil, err: string | nil) -> Signature
local function must_sig(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: NarrowVocab | nil, err: string | nil) -> NarrowVocab
local function must_narrow(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: AxiomDecl | nil, err: string | nil) -> AxiomDecl
local function must_axiom(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: unknown, err: string | nil) -> unknown
local function must_spine(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: AssignEffectsVocab | nil, err: string | nil) -> AssignEffectsVocab
local function must_effects(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: NarrowPersist | nil, err: string | nil) -> NarrowPersist
local function must_persist(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: Term | nil, err: string | nil) -> Term
local function must_term(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: ExtractStats | nil, err: string | nil) -> ExtractStats
local function must_stats(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: Replayer | nil, err: string | nil) -> Replayer
local function must_rp(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--:: Setup = {
--::   store: Store, stats: ExtractStats, narrow: NarrowVocab,
--::   rp: Replayer, registry: Registry,
--:: }

-- Declare a fresh theory stack, extract `source` into a fresh store, register
-- the SOUND rule set (see extractor_v1.lua's header: `narrow-select-match`,
-- never `narrow-select-rest`), and run to fixpoint.
--: (source: string) -> Setup
local function run_on(source)
	-- Each result is captured into (value, err) locals before the `must_*`
	-- call: passing a two-value call directly as one argument is a distinct
	-- (and rejected) shape under this typechecker — same convention as
	-- engine_test.lua.
	local addr_raw, addr_err = addr_v1.declare()
	local addr_sig = must_sig(addr_raw, addr_err)
	local reg = rl.new_registry()
	local narrow_raw, narrow_err = flow_narrow_v1.declare_vocabulary(reg, addr_sig)
	local narrow = must_narrow(narrow_raw, narrow_err)
	local ax_raw, ax_err = pilot_initial_facts_v1.declare(reg, narrow)
	local ax_initial = must_axiom(ax_raw, ax_err)
	local spine_raw, spine_err = effects_spine_v1.declare(addr_sig)
	local spine = must_spine(spine_raw, spine_err)
	local eff_raw, eff_err = assign_effects_v1.declare_vocabulary(reg, addr_sig, spine)
	local effects = must_effects(eff_raw, eff_err)
	local per_raw, per_err = narrow_persist_v1.declare(reg, narrow, spine)
	local persist = must_persist(per_raw, per_err)

	local fid_raw, fid_err = extractor.file_id_of_source(addr_sig.ops, source)
	local file_id = must_term(fid_raw, fid_err)
	local store = engine.new_store()
	local bundle = {
		addr_ops = addr_sig.ops, file_id = file_id, narrow = narrow,
		ax_initial = ax_initial, effects = effects,
	}
	local stats_raw, stats_err = extractor.extract(store, bundle, source, "test.lua")
	local stats = must_stats(stats_raw, stats_err)

	local r1, e1 = engine.add_rule(store, narrow.rule_match)
	T.ok(r1, e1)
	local r2, e2 = engine.add_rule(store, effects.rule_transfer)
	T.ok(r2, e2)
	local r3, e3 = engine.add_rule(store, effects.rule_trans)
	T.ok(r3, e3)
	local r4, e4 = engine.add_rule(store, persist.rule_persist)
	T.ok(r4, e4)
	local ran, run_err = engine.run(store)
	T.ok(ran, run_err)

	local rp_raw, rp_err = rl.new_replayer({ registry = reg })
	local rp = must_rp(rp_raw, rp_err)
	return { store = store, stats = stats, narrow = narrow, rp = rp, registry = reg }
end

-- Every `holds_at` fact in the store, replayed root-strict against the real
-- kernel. Returns the count; fails the test on any rejection — the engine's
-- provenance must be independently acceptable, never taken on trust.
--: (s: Setup) -> integer
local function replay_all_holds_at(s)
	local facts = engine.facts_of(s.store, "holds_at")
	for i = 1, #facts do
		local node, cerr = engine.to_certificate(facts[i])
		T.ok(node, cerr)
		if node then
			local result, rerr = rl.replay(s.rp, node)
			T.ok(result, rerr)
		end
	end
	return #facts
end

-- Is some `holds_at` fact in the store derived by a rule (not just seeded)?
--: (s: Setup) -> integer
local function derived_holds_at_count(s)
	local facts = engine.facts_of(s.store, "holds_at")
	local n = 0
	for i = 1, #facts do
		if facts[i].provenance.kind == "rule" then n = n + 1 end
	end
	return n
end

-- Does some `holds_at` fact's provenance chain through BOTH theories — a
-- narrowing rule AND a `preserves` premise produced by the effects theory?
-- That is the composition-only criterion phase 5 measures, checked
-- structurally rather than by counting.
--: (fact: Fact) -> boolean
local function chains_through_spine(fact)
	local prov = fact.provenance
	if prov.kind ~= "rule" then return false end
	local rule = prov.rule
	if rule and rule.name == "narrow-persist" then return true end
	local prems = prov.premises
	if not prems then return false end
	for i = 1, #prems do
		if chains_through_spine(prems[i]) then return true end
	end
	return false
end

--: (s: Setup) -> integer
local function composition_count(s)
	local facts = engine.facts_of(s.store, "holds_at")
	local n = 0
	for i = 1, #facts do
		if chains_through_spine(facts[i]) then n = n + 1 end
	end
	return n
end

T.describe("extractor_v1: single-clause guard", function()
	T.it("seeds a citable guard + declared-type fact whose narrowing derivation replays root-strict", function()
		local s = run_on([[
local x --: string | nil
if type(x) == "string" then
	print(x)
end
]])
		T.eq(s.stats.tracked_vars, 1)
		T.eq(s.stats.guards_seeded, 1)
		T.eq(s.stats.initial_facts_seeded, 1)
		T.ok(derived_holds_at_count(s) >= 1, "no narrowing was derived")
		T.ok(replay_all_holds_at(s) >= 2)
	end)

	T.it("emits NO guard fact for the complementary branch (the branch-role fork stays untouched)", function()
		-- `x ~= nil` selects `nil` on the ELSE side; with no else block there is
		-- no addressable continuation, so nothing is asserted.
		local s = run_on([[
local x --: string | nil
if x ~= nil then
	print(x)
end
]])
		T.eq(s.stats.guards_seeded, 0)
		T.ok(s.stats.skipped["guard's selected branch is the (absent) else continuation"])
	end)
end)

T.describe("extractor_v1: elseif chains", function()
	T.it("extracts a guard from EVERY clause of a chain, not just the first", function()
		local s = run_on([[
local x --: string | number | nil
if type(x) == "string" then
	print(x)
elseif type(x) == "number" then
	print(x)
else
	print(x)
end
]])
		T.eq(s.stats.guards_seeded, 2)
		T.eq(s.stats.initial_facts_seeded, 2)
		-- Both clauses narrow, independently, at their own branch entry.
		T.ok(derived_holds_at_count(s) >= 2, "elseif clause did not narrow")
		T.ok(replay_all_holds_at(s) >= 4)
	end)

	T.it("routes a failing clause's selected branch to the NEXT clause's test point", function()
		-- `x == nil` on clause 0 selects `nil` on the then-side; clause 1's
		-- guard is what the else side reaches. The `~=` form below makes the
		-- selected branch the continuation, which for a chain is clause 1's
		-- own test expression.
		local s = run_on([[
local x --: string | nil
if x ~= nil then
	print(x)
elseif type(x) == "string" then
	print(x)
end
]])
		T.eq(s.stats.guards_seeded, 2)
		T.ok(replay_all_holds_at(s) >= 2)
	end)
end)

T.describe("extractor_v1: preservation chains and cross-theory composition", function()
	T.it("composes narrowing with the effects spine across a WHOLE statement chain", function()
		local s = run_on([[
local x --: string | nil
if type(x) == "string" then
	print("a")
	print("b")
	print(x)
end
]])
		-- Three non-interfering statements in the match branch: the narrowed
		-- fact must reach the exit of each, via `preserves` (spine) premises.
		T.eq(s.stats.preserve_facts_seeded, 3)
		T.ok(composition_count(s) >= 3,
			"narrow-persist did not carry the narrowed fact along the statement chain")
		T.ok(replay_all_holds_at(s) >= 4)
	end)

	T.it("stops the chain at a statement whose non-interference is not structurally verified", function()
		local s = run_on([[
local x --: string | nil
if type(x) == "string" then
	print("a")
	if other then print("b") end
	print(x)
end
]])
		-- Only the first statement's span is verified in the OUTER chain; the
		-- nested `if` ends it rather than being assumed safe. The nested
		-- branch's own body then starts a fresh chain from its own block entry
		-- (one fact for `print("b")`) — a true span fact that simply derives
		-- nothing, since no `holds_at` is known at that block's entry.
		T.eq(s.stats.preserve_facts_seeded, 2)
		T.ok(replay_all_holds_at(s) >= 2)
	end)

	T.it("emits no preservation fact across an assignment to the tracked variable", function()
		local s = run_on([[
local x --: string | nil
if type(x) == "string" then
	x = nil
	print(x)
end
]])
		-- No fact spans the assignment itself. The span AFTER it
		-- (`x = nil` exit -> `print(x)` exit) is emitted and is true — `print`
		-- writes nothing — but nothing is known at its `from` point, so no
		-- narrowing survives the assignment. Composition count, not fact
		-- count, is the assertion that matters here.
		T.eq(s.stats.preserve_facts_seeded, 1)
		T.eq(composition_count(s), 0)
	end)
end)

T.describe("extractor_v1: parameters and scope", function()
	T.it("tracks an annotated parameter and narrows inside the function body", function()
		local s = run_on([[
--: (string | nil) -> ()
local function f(s)
	if type(s) == "string" then
		print(s)
	end
end
]])
		T.eq(s.stats.tracked_vars, 1)
		T.eq(s.stats.guards_seeded, 1)
		T.ok(derived_holds_at_count(s) >= 1)
		T.ok(replay_all_holds_at(s) >= 2)
	end)

	T.it("drops a tracked variable shadowed by a later local declaration", function()
		local s = run_on([[
local x --: string | nil
local x = 1
if type(x) == "string" then
	print(x)
end
]])
		T.eq(s.stats.guards_seeded, 0)
		T.ok(s.stats.skipped["tracked variable shadowed by a later local declaration"])
	end)

	T.it("never leaks an outer tracked variable into a nested function's scope", function()
		local s = run_on([[
local x --: string | nil
local function g(y)
	if type(x) == "string" then
		print(x)
	end
end
]])
		-- `g`'s body gets a FRESH scope built only from its own annotated
		-- parameters (there are none), so the outer `x` is invisible there.
		T.eq(s.stats.guards_seeded, 0)
	end)
end)

T.describe("extractor_v1: real repository source", function()
	T.it("extracts and derives on lib/table_ext/init.lua without any replay rejection", function()
		local fh = io.open("lib/table_ext/init.lua", "r")
		T.ok(fh, "could not open lib/table_ext/init.lua")
		if not fh then return end
		local source = fh:read("*a")
		fh:close()
		T.ok(type(source) == "string")
		if type(source) ~= "string" then return end

		local s = run_on(source)
		T.ok(s.stats.guards_seeded >= 1, "no guard extracted from a file known to contain one")
		-- Every derived judgment is independently accepted by the kernel.
		T.ok(replay_all_holds_at(s) >= 1)
	end)
end)
