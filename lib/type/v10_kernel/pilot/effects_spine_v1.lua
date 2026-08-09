-- lib/type/v10_kernel/pilot/effects_spine_v1.lua
--
-- Corroboration proof-of-concept, spine step 1 — the FIRST real spine
-- vocabulary beyond the core (docs/decisions/typechecker-v10-core-design.md,
-- "Corroboration/co-solving design-input note": "Exchange is SPINE-MEDIATED
-- ONLY: all cross-theory facts are judgments in layer (spine) vocabulary;
-- there is no pairwise/bridge vocabulary between theories"). Declared over
-- the canonical v10 core (lib/type/v10_cleanroom/, per the owner-ratified
-- canon swap), importing `point`/`path` from addr-v1
-- (lib/type/v10_kernel/pilot/addr_v1.lua) — the same addressing spine every
-- pilot theory already shares.
--
-- fable-delegation-tier throughout (per the core design's pilot-execution
-- delegation note): every choice here is a delegated-execution decision,
-- re-openable on challenge, not an owner ratification.
--
-- ── Why this file exists as a THIRD signature, distinct from both theories ──
--
-- The existing pilot precedent (flow_narrow_v1.lua / fixpoint_v1.lua) grew
-- narrowing's and the fixpoint/effects content's judgment vocabulary
-- (`holds_at`, `stmt_seq`, `stmt_preserves`, `assign_*`, ...) inside ONE
-- JOINTLY-VERSION-BUMPED signature, `narrow-pilot-v1` — a single object
-- successive theory modules kept extending. That is exactly the coupling
-- shape the corroboration note's spine-mediated principle rules out: two
-- theories sharing one signature they both add operators to is pairwise/
-- bridge vocabulary by another name (whichever theory bumps the version
-- next is deciding the other's vocabulary surface). This module is the
-- corrective: a signature owned by NEITHER theory ("the layer"), declaring
-- only the shared judgment shape both sides need, that narrowing (which
-- CONSUMES it) and the effects theory (which PRODUCES it) each import/cite
-- independently, never seeing each other's own signature at all. See
-- narrow_persist_v1.lua (consumer) and assign_effects_v1.lua (producer).
--
-- ── The judgment: `preserves(from, to, x)` ──────────────────────────────────
--
-- `preserves(from: point, to: point, x: path) : judgment` reads: "the
-- binding at path `x` is unchanged across control flow from point `from` to
-- point `to`" — a POSITIVE preservation judgment, not "nothing happened":
-- any producing theory may derive it via whatever rules ground it (a single
-- non-interfering statement, a whole loop body proven not to touch `x`,
-- etc.) — the spine only fixes the SHAPE of the claim, never how it is
-- proven. Per the design brief's working defaults (delegation-tier, not
-- owner-ratified, overridable by a recorded reason — none arose building
-- this): "positive preservation judgments... negation internalized in the
-- producing theory, spine stays positive; locals only, no table fields (no
-- aliasing theory exists)." `x`'s sort is addr-v1's `path`, which pilot
-- addressing already restricts to declaration-site identity paths for
-- locals/parameters (pilot/addr_v1.lua, pilot/prover_addr.lua) — there is
-- no field-projection operator anywhere in this pilot's addressing
-- vocabulary, so "locals only, no aliasing" is enforced by the shared
-- addressing signature's own vocabulary, not by an extra side condition
-- here.
--
-- No axiom, no rule, nothing but the bare judgment shape lives here — a
-- spine signature is vocabulary only, exactly like addr-v1's own
-- "deliberately signature-only" discipline (see that module's header).
-- Rules that PRODUCE or CONSUME `preserves` facts belong to the theories
-- that cite this signature's `ops.preserves`, never to this module.

local ta = require("lib.type.v10_cleanroom.term_algebra")

local M = {}

--:: EffectsSpine = { signature: Signature, Preserves: (from: Term, to: Term, x: Term) -> (Term | nil, string | nil) }

-- Declare the effects spine signature (`effects-spine-v1` v1) into the
-- given registry^H^H^H^H^H^H^H^H — signatures are NOT registry objects
-- (only axioms/rules are; see lib/type/v10_cleanroom/replayer.lua) — this
-- declares a standalone Signature object, shared by citing the same
-- returned object, exactly like addr_v1.declare(). Caps-clean: `addr_sig`
-- is injected, never reached for ambiently.
-- `addr_sig` is typed `unknown` and narrowed by hand: a `type(x) ~= "table"`
-- guard on an already-record-typed parameter widens the else branch back to
-- `unknown` (the same typechecker gotcha every other pilot module in this
-- directory documents), so the runtime guard runs on `unknown` and a
-- checked cast restores the shape.
--: (addr_sig: unknown) -> (EffectsSpine | nil, string | nil)
function M.declare(addr_sig)
	if type(addr_sig) ~= "table" then
		return nil, "effects_spine_v1.declare: addr_sig (a declared addr-v1 signature) is required"
	end
	local sig_in = addr_sig --[[: Signature ]]
	local addr_sorts = sig_in.sorts
	if type(addr_sorts) ~= "table" or not addr_sorts.point or not addr_sorts.path then
		return nil, "effects_spine_v1.declare: addr_sig must declare point and path sorts"
	end

	local sig, sig_err = ta.declare_signature({
		name = "effects-spine-v1",
		version = 1,
		sorts = { "judgment" },
		imports = { { from = sig_in, sorts = { "point", "path" } } },
		ops = {
			preserves = {
				result = "judgment",
				args = { { sort = "point" }, { sort = "point" }, { sort = "path" } },
			},
		},
	})
	if not sig then return nil, sig_err end
	local ops = sig.ops

	--: (from: Term, to: Term, x: Term) -> (Term | nil, string | nil)
	local function Preserves(from, to, x) return ta.build(ops.preserves, { from, to, x }) end

	return { signature = sig, Preserves = Preserves }
end

return M
