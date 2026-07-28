-- lib/type/v10_kernel/pilot/pilot_initial_facts_v1.lua
--
-- Pilot step 4 (certificate-emitting prover) — the SECOND reality-boundary
-- axiom, alongside flow_narrow_v1.lua's `pilot-syntax-facts-v1`. Where that
-- axiom asserts "the parser saw this guard shape," this one asserts "the
-- parser saw this `--:` annotation on this local declaration" — the other
-- half of "how do ground facts about a real file enter a derivation."
--
-- ── Why an axiom citation, not a hypothesis ──────────────────────────────────
--
-- flow_narrow_v1_test.lua's own worked examples introduce the "type at the
-- guard point" fact as a HYPOTHESIS (`replayer.hypothesis(...)`), which
-- stays permanently open (undischarged — neither narrowing rule declares a
-- discharge slot). That is correct for a THEORY's unit tests (a hypothesis
-- is exactly "assume this and see what follows"), but the prover is not
-- assuming anything: an annotation actually present in a real source file
-- is an observed fact about that file, exactly like a guard's syntax shape.
-- Citing it via a schematic axiom (never a hypothesis) means: (a) it costs
-- nothing to leave "open" because axiom citations never are — replay_root
-- can accept a root judgment built entirely from axiom citations and rule
-- applications with zero undischarged hypotheses; (b) the axiom key tags
-- every derivation using it, honestly pricing "trust the annotation
-- actually says what the prover claims" exactly as
-- `pilot-syntax-facts-v1@v1` prices "trust the guard shape."
--
-- ── No new operator needed ───────────────────────────────────────────────────
--
-- The judgment shape needed is exactly `holds_at(point, path, ty)` —
-- narrow-pilot-v1's OWN existing op, already imported/available on the same
-- v2 signature object flow_narrow_v1.lua declares (see its header for why a
-- v2 signature, not a fresh one, is the right home for anything the
-- narrowing rules must cite alongside). So this module declares ONE new
-- axiom over an ALREADY-declared signature + HoldsAt builder (passed in via
-- `vocab`, the return value of flow_narrow_v1.declare_vocabulary) — no
-- `declare_signature` call here at all, unlike pilot-syntax-facts-v1 (whose
-- `guard_selects` op genuinely needed new vocabulary). Per the task brief's
-- own instruction: "if holds_at itself ... is enough ... no new op is
-- needed, just a new axiom over existing narrow-pilot-v1 v2 vocabulary" —
-- confirmed by working through the concrete case (an annotation fact is
-- exactly "at this point, this path has this type," nothing more).
--
-- The pattern `holds_at(P, X, T)` is fully schematic (three open
-- metavariables) — structurally identical in shape to
-- `pilot-syntax-facts-v1`'s fully-open `guard_selects(Pg,Pb,X,TA)`. This is
-- deliberate, not a laxer version of the same idea: the axiom mechanism's
-- soundness never came from constraining WHAT a schematic axiom's pattern
-- can range over (nothing does — see core design doc, "Axioms are
-- schematic"); it comes from every CONCRETE citation being tainted with the
-- axiom's key, so a prover that lies about what a real annotation said
-- produces a certificate that is honestly priced as trusting this axiom,
-- not one that is silently "proven" some other way.

local replayer = require("lib.type.v10_kernel.replayer")

local M = {}

--:: Vocab = { signature: unknown, HoldsAt: (unknown, unknown, unknown) -> (unknown | nil, string | nil), [string]: unknown }
--:: AxiomDecl = unknown

-- Declare `pilot-initial-facts-v1` (version 1) over an already-built
-- flow_narrow_v1 vocabulary. `k` (a term_algebra tier instance) and `vocab`
-- are both injected, caps-clean, never reached for ambiently.
--: (k: unknown, vocab: Vocab) -> (AxiomDecl | nil, string | nil)
function M.declare(k, vocab)
	if type(k) ~= "table" then return nil, "declare: k (a term_algebra instance) is required" end
	local kt = k --[[: { build_meta: (string, unknown) -> (unknown | nil, string | nil) } ]]
	if type(kt.build_meta) ~= "function" then return nil, "declare: k must be a term_algebra tier instance" end

	if type(vocab) ~= "table" then return nil, "declare: vocab (a declared flow_narrow_v1 vocabulary) is required" end
	local v = vocab --[[: Vocab ]]
	local sig_raw = v.signature
	if type(sig_raw) ~= "table" or type(v.HoldsAt) ~= "function" then
		return nil, "declare: vocab must be flow_narrow_v1.declare_vocabulary's return value"
	end
	local sig = sig_raw --[[: { name: string, version: integer, sorts: { [string]: unknown }, sort_set: { [unknown]: boolean }, ops: unknown } ]]

	local p = kt.build_meta("P", sig.sorts.point)
	local x = kt.build_meta("X", sig.sorts.path)
	local t = kt.build_meta("T", sig.sorts.ty)
	if not p or not x or not t then return nil, "declare: failed to build schematic metavariables" end

	local pattern, perr = v.HoldsAt(p, x, t)
	if not pattern then return nil, perr end

	return replayer.declare_axiom({
		name = "pilot-initial-facts-v1", version = 1, signature = sig,
		pattern = pattern,
	})
end

return M
