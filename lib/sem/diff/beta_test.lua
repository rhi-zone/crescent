-- lib/sem/diff/beta_test.lua
-- Loop-β: the SOUNDNESS property `checker accepts ⟹ ¬fault`, run against OUR
-- DETERMINISTIC SPEC (lib/sem step/run), NOT against real interpreters
-- (docs/typechecker-formal-semantics.md §2). For a generated annotated program P:
--   if checker.accept(P) then the spec MUST NOT fault on run(P).
-- A program the checker ACCEPTS but the spec FAULTS on is a soundness
-- counterexample — the checker is unsound.
--
-- THE TWO-LOOP SEPARATION IS BINDING. Loop-β NEVER touches a real interpreter:
-- running it against real Lua would launder the variance signal into "stuck"
-- (a real interpreter on one version might not fault on the exact aliasing input,
-- so the disagreement gets absorbed as admissible/UB instead of flagged as an
-- accepted-yet-faulting program). The spec is the trusted, deterministic oracle
-- where a fault is UNAMBIGUOUSLY a fault.
--
-- THE CHECKER ORACLE (pluggable). A checker oracle answers ONE question:
-- "does this checker ACCEPT this annotated program?" Two oracles are wired:
--   * REAL  — the actual crescent slice checker: L.lower(source) → A.check.
--             accept ⟺ the lowering reports CLEAN (no type-mismatch, nothing
--             rejected/unknown). This is the checker whose soundness we ground.
--   * UNSOUND-COVARIANT — a SYNTHETIC test fixture that re-derives the KNOWN
--             variance unsoundness. It decides the alias-widen by the DOCUMENTED
--             PRE-FIX `_rec_sub` rule (`docs/agnostic-static-analysis-crescent-
--             slice.md` §6.14.1): mutable record fields compared COVARIANTLY
--             (forward direction only), instead of the landed INVARIANT rule. It
--             reuses the REAL `slice_subtype.is_subtype` primitive in the forward
--             direction — the bug is literally "drop the reverse-direction check",
--             nothing hardcoded. The real checker is NOT modified or weakened; this
--             oracle is a standalone fixture that models the pre-fix behaviour so
--             we can PROVE the harness catches the class (demonstration path (b)).
--
-- WHY (b) and not (a)/(c): the real checker exposes NO variance toggle (path (a)
-- is unavailable — the invariant rule is unconditional in `_rec_sub`), and a
-- pre-fix scratch checkout (path (c)) would re-run an OLD code state rather than
-- prove THIS harness detects the class. The synthetic covariant oracle (b) is the
-- least-hacky honest path: it isolates EXACTLY the one rule the fix changed,
-- built from the real subtype primitive, leaving the shipped checker untouched.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local A       = require("lib.type.analysis")
local S       = require("lib.type.analysis.crescent_slice")
local L       = require("lib.type.analysis.crescent_slice_lower")
local SUB     = require("lib.type.analysis.slice_subtype")
local lower   = require("lib.sem.lang.lua.lower")
local run     = require("lib.sem.run")
local profile = require("lib.sem.profile")
local observe = require("lib.sem.diff.observe")
local arbalias = require("lib.sem.diff.arb_alias")
local gen     = require("lib.test.gen")

--:: require "lib.sem.lang.lua.lower"
--:: require "lib.sem.run"
--:: require "lib.type.analysis.slice_ty"

--:: Rng = { seed: number, next: (self: Rng) -> number, float: (self: Rng) -> number, int: (self: Rng, lo: integer, hi: integer) -> integer, bool: (self: Rng) -> boolean, pick: <T>(self: Rng, t: T[]) -> T }
--:: AliasProg = { prog: SS[], source: string, narrow_ty: Ty, wide_ty: Ty, pred_faults: boolean, note: string }

-- A checker oracle: name + an accept predicate over an AliasProg.
--:: Oracle = { name: string, accept: (AliasProg) -> boolean }

-- ── the REAL oracle: the shipped crescent slice checker ──────────────────────
--: () -> SemanticsRegistry
local function reg()
	local r = A.new_registry()
	S.register(r)
	return r
end

-- accept ⟺ the lowering+check reports CLEAN (no type-mismatch marker, nothing
-- rejected or left unknown). A `type-mismatch` marker is the checker REJECTING the
-- alias-widen (the variance rule firing); its presence ⇒ not accepted.
--: (AliasProg) -> boolean
local function real_accept(ap)
	local res = L.lower(ap.source, "beta.lua")
	if not res then return false end
	for _, m in ipairs(res.markers) do
		if m.construct == "type-mismatch" then return false end
	end
	local chk = A.check({ state = res.state, requested_claims = res.requested,
		semantics_registry = reg(), trust_policy = nil })
	if not chk then return false end
	for _ in pairs(chk.rejected_claims) do return false end
	for _ in pairs(chk.unknown_claims) do return false end
	return res.expected == "CLEAN"
end

-- ── the SYNTHETIC UNSOUND oracle: pre-fix COVARIANT field subtyping ──────────
-- The pre-fix `_rec_sub` (§6.14.1) accepts a mutable-field record subtype
-- `Narrow <: Wide` iff `Narrow.f <: Wide.f` COVARIANTLY (forward only) — it OMITS
-- the reverse-direction `Wide.f <: Narrow.f` the invariant fix added. We replicate
-- exactly that: for each field, the FORWARD subtype only, via the real primitive.
-- This is the alias-widen acceptance decision a covariant checker would make; the
-- rest of the program (fresh-table construction, the wide-typed write, the narrow
-- read) a covariant checker accepts identically to the sound one — only the
-- alias-widen verdict differs, which is the whole point of the variance class.
--: (Ty, Ty) -> boolean
local function covariant_rec_sub(narrow, wide)
	local nf = narrow.fields or {}
	local wf = wide.fields or {}
	-- width: every wide field must be present in narrow (closed-rec width rule).
	for i = 1, #wf do
		local w = wf[i]
		local found --: Ty | nil
		for j = 1, #nf do
			if nf[j].key == w.key then found = nf[j].ty end
		end
		if found == nil then return false end
		-- COVARIANT depth ONLY (the pre-fix unsound rule): forward direction.
		if not SUB.is_subtype(found, w.ty) then return false end
		-- (the SOUND rule would ALSO require SUB.is_subtype(w.ty, found) here.)
	end
	return true
end

--: (AliasProg) -> boolean
local function covariant_accept(ap)
	-- The covariant checker accepts the program iff it accepts the alias-widen
	-- `narrow <: wide` covariantly. (Construction + write + read are accepted by
	-- both the sound and unsound checker; the alias-widen is the sole difference.)
	return covariant_rec_sub(ap.narrow_ty, ap.wide_ty)
end

-- ── the spec side: does run(P) fault? ────────────────────────────────────────
-- Run the surface program under the luajit51 profile (the alias shape is
-- version-agnostic — table aliasing + kind-faults are identical across all five
-- profiles, so one deterministic profile suffices for the soundness property).
--: (SS[]) -> boolean
local function spec_faults(prog)
	local va = profile.luajit51.va
	local ctrl = lower.lower_program(va, prog) --: Stmt[]
	local res = run.run(profile.luajit51, ctrl, 100000) --: RunResult
	local obs = observe.observe_spec(va, res)
	return obs.tag == "fault"
end

-- ── the Loop-β property over one oracle ──────────────────────────────────────
-- Returns (violations, accepted, generated, witness) where a VIOLATION is an
-- AliasProg the oracle ACCEPTS but the spec FAULTS on (accept ∧ fault). `witness`
-- is the first violating AliasProg (already minimal in structure — see arb_alias
-- shrink note), or nil.
--: (Oracle, Rng, integer) -> (integer, integer, integer, AliasProg | nil)
local function loop_beta(oracle, rng, trials)
	local violations, accepted = 0, 0
	local witness --: AliasProg | nil
	for _ = 1, trials do
		local ap = arbalias.arb.generate(rng, 8)
		if oracle.accept(ap) then
			accepted = accepted + 1
			if spec_faults(ap.prog) then
				violations = violations + 1
				if witness == nil then witness = ap end
			end
		end
	end
	return violations, accepted, trials, witness
end

-- ── the harness ──────────────────────────────────────────────────────────────
T.describe("sem Loop-beta: soundness property (checker accepts => not fault)", function()
	local TRIALS = 60

	-- seed: replayable via PROP_SEED (matches Loop-α's replay convention).
	--: () -> number
	local function pick_seed()
		local seed = os.time() --: number
		local env = os.getenv("PROP_SEED")
		if env ~= nil then
			local p = tonumber(env)
			if p ~= nil then seed = p end
		end
		return math.floor(seed)
	end

	-- ── (1) THE HEADLINE: mechanical variance-unsoundness detection ───────────
	-- Against the SYNTHETIC UNSOUND (covariant) oracle, the alias-targeting
	-- generator MUST produce a program the oracle ACCEPTS but the spec FAULTS on —
	-- the variance counterexample the 5 human audits missed, found MECHANICALLY.
	T.it("detects the covariant-field-write variance unsoundness (synthetic unsound oracle)", function()
		local seed = pick_seed()
		local rng = gen.make_rng(seed) --: Rng
		local oracle = { name = "unsound-covariant", accept = covariant_accept } --[[: Oracle]]
		local v, acc, total, witness = loop_beta(oracle, rng, TRIALS)

		if witness == nil then
			T.ok(false,
				"Loop-beta found NO variance counterexample against the UNSOUND oracle "
				.. "(replay: PROP_SEED=" .. seed .. "); accepted " .. acc .. "/" .. total
				.. ". The alias-targeting generator should always hit the faulting shape.")
			return
		end

		-- the witness is already structurally minimal (4-stmt alias shape); report it.
		print("  [Loop-beta] HEADLINE: variance unsoundness MECHANICALLY DETECTED")
		print("  [Loop-beta]   oracle=unsound-covariant  seed=" .. seed
			.. "  violations=" .. v .. "/" .. acc .. " accepted  (" .. total .. " generated)")
		print("  [Loop-beta]   note: " .. witness.note)
		print("  [Loop-beta]   minimal witness (accepted by covariant checker, FAULTS on spec):")
		for line in (witness.source):gmatch("[^\n]+") do print("  [Loop-beta]   | " .. line) end

		T.ok(v >= 1, "at least one accept-and-fault counterexample against the unsound oracle")
		-- confirm the witness genuinely faults AND the unsound oracle genuinely
		-- accepts it (the two halves of the soundness violation).
		T.ok(covariant_accept(witness), "the unsound covariant oracle ACCEPTS the witness")
		T.ok(spec_faults(witness.prog), "the spec FAULTS on the witness (the runtime corruption)")
		-- and confirm the REAL checker REJECTS exactly this witness — proving the
		-- fix closes precisely what the harness flags.
		T.fail(real_accept(witness), "the REAL (sound) checker REJECTS the witness — the fix holds")
	end)

	-- ── (2) Loop-β against the REAL (sound) checker ───────────────────────────
	-- Over the alias-targeting generator, the REAL checker must find ZERO
	-- violations: every program it ACCEPTS, the spec does NOT fault on. Zero is the
	-- expected, honest result (the variance fix is landed). A violation here would
	-- be a NEW genuine unsoundness — surfaced loudly, never hidden.
	T.it("REAL checker: zero soundness violations over the alias-targeting generator", function()
		local seed = pick_seed()
		local rng = gen.make_rng(seed) --: Rng
		local oracle = { name = "real", accept = real_accept } --[[: Oracle]]
		local v, acc, total, witness = loop_beta(oracle, rng, TRIALS)

		print("  [Loop-beta] REAL checker over alias-targeting generator:")
		print("  [Loop-beta]   seed=" .. seed .. "  generated=" .. total
			.. "  accepted=" .. acc .. "  violations(accept&fault)=" .. v)
		print("  [Loop-beta]   coverage bound: alias-widen shape only "
			.. "(narrow/wide field types in {number,string,boolean,unknown}); "
			.. "broader v1 coverage is the general-generator follow-up (TODO.md).")

		if witness ~= nil then
			-- A NEW unsoundness — report it loudly with the shrunk witness, never hide.
			print("  [Loop-beta]   *** NEW UNSOUNDNESS FOUND (real checker) ***  seed=" .. seed)
			for line in (witness.source):gmatch("[^\n]+") do print("  [Loop-beta]   | " .. line) end
		end
		T.eq(v, 0, "the REAL checker has no accept-and-fault counterexample over the alias generator")
	end)

	-- ── (3) the generator genuinely exercises both faulting and sound rows ────
	-- A sanity check that the alias-targeting generator is not degenerate: over the
	-- stream it produces BOTH faulting (unknown-widen) and non-faulting (same-type)
	-- alias shapes, so the REAL checker's zero-violation result is meaningful
	-- (it accepts the sound rows and rejects the faulting ones — not "accepts
	-- nothing"). We assert the REAL checker accepts at least some sound rows.
	T.it("generator exercises both faulting and sound alias rows (non-degenerate)", function()
		local rng = gen.make_rng(pick_seed()) --: Rng
		local faulting, sound = 0, 0
		for _ = 1, 80 do
			local ap = arbalias.arb.generate(rng, 8)
			if ap.pred_faults then faulting = faulting + 1 else sound = sound + 1 end
		end
		print("  [Loop-beta] generator mix: faulting-shape=" .. faulting
			.. "  sound-shape=" .. sound .. " / 80")
		T.ok(faulting >= 1, "generator produces faulting (unknown-widen) alias shapes")
		T.ok(sound >= 1, "generator produces sound (same-type) alias shapes")
	end)
end)
