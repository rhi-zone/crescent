-- lib/type/v10_kernel/pilot/pilot_initial_facts_v1.lua
--
-- Pilot step 4 (certificate-emitting prover) — the SECOND reality-boundary
-- axiom, alongside flow_narrow_v1.lua's `pilot-syntax-facts-v1`. Where that
-- axiom asserts "the parser saw this guard shape," this one asserts "the
-- parser saw this `--:` annotation on this local declaration" — the other
-- half of "how do ground facts about a real file enter a derivation."
-- Declared over the canonical v10 core (lib/type/v10_cleanroom/, per the
-- owner-ratified canon swap).
--
-- ── Why an axiom citation, not a hypothesis ──────────────────────────────────
--
-- flow_narrow_v1_test.lua's worked examples introduce the "type at the
-- guard point" fact as a HYPOTHESIS, which stays permanently open
-- (undischarged — neither narrowing rule declares a discharge slot). That
-- is correct for a THEORY's unit tests (a hypothesis is exactly "assume
-- this and see what follows"), but the prover is not assuming anything: an
-- annotation actually present in a real source file is an observed fact
-- about that file, exactly like a guard's syntax shape. Citing it via a
-- schematic axiom (never a hypothesis) means: (a) it costs nothing to
-- leave "open" because axiom citations never are — root-strict replay can
-- accept a root judgment built entirely from axiom citations and rule
-- applications with zero undischarged hypotheses; (b) the axiom key tags
-- every derivation using it, honestly pricing "trust the annotation
-- actually says what the prover claims."
--
-- ── No new operator needed ───────────────────────────────────────────────────
--
-- The judgment shape needed is exactly `holds_at(point, path, ty)` —
-- narrow-pilot-v1's OWN existing op, already available on the same v2
-- signature object flow_narrow_v1.lua declares. So this module declares
-- ONE new axiom over an ALREADY-declared signature + HoldsAt builder
-- (passed in via `vocab`, the return value of
-- flow_narrow_v1.declare_vocabulary) — no `declare_signature` call here.
--
-- The pattern `holds_at(P, X, T)` is fully schematic (three open
-- metavariables) — structurally identical in shape to
-- `pilot-syntax-facts-v1`'s fully-open `guard_selects(Pg,Pb,X,TA)`. This is
-- deliberate, not a laxer version of the same idea: the axiom mechanism's
-- soundness never came from constraining WHAT a schematic axiom's pattern
-- can range over; it comes from every CONCRETE citation being tainted with
-- the axiom's key, so a prover that lies about what a real annotation said
-- produces a certificate that is honestly priced as trusting this axiom.

local ta = require("lib.type.v10_cleanroom.term_algebra")
local replayer = require("lib.type.v10_cleanroom.replayer")
local flow_narrow_v1 = require("lib.type.v10_kernel.pilot.flow_narrow_v1")

local M = {}

-- Declare `pilot-initial-facts-v1` (version 1) into the given registry,
-- over an already-built flow_narrow_v1 vocabulary. Both are injected,
-- caps-clean, never reached for ambiently. The registry must be the same
-- one the vocabulary was declared into (the prover's replayer resolves
-- citations against exactly one registry).
-- `vocab` is typed `unknown` and narrowed by hand (same typechecker
-- gotcha as flow_narrow_v1.declare_vocabulary's addr_sig parameter: a
-- `type(x)` guard on a record-typed parameter widens it to `unknown`).
--: (registry: Registry, vocab: unknown) -> (AxiomDecl | nil, string | nil)
function M.declare(registry, vocab)
	if type(vocab) ~= "table" then
		return nil, "declare: vocab (a declared flow_narrow_v1 vocabulary) is required"
	end
	local v = vocab --[[: NarrowVocab ]]
	local sig = v.signature
	if type(sig) ~= "table" or type(v.HoldsAt) ~= "function" then
		return nil, "declare: vocab must be flow_narrow_v1.declare_vocabulary's return value"
	end
	-- re-cast after the runtime guard (the type() check widens `sig` back
	-- to `unknown` — same gotcha as the parameter itself)
	local sig_t = sig --[[: Signature ]]

	local p = ta.meta("P", sig_t.sorts.point)
	local x = ta.meta("X", sig_t.sorts.path)
	local t = ta.meta("T", sig_t.sorts.ty)
	if not p or not x or not t then return nil, "declare: failed to build schematic metavariables" end

	local pattern, perr = v.HoldsAt(p, x, t)
	if not pattern then return nil, perr end

	return replayer.declare_axiom(registry, {
		name = "pilot-initial-facts-v1", version = 1,
		pattern = pattern,
	})
end

return M
