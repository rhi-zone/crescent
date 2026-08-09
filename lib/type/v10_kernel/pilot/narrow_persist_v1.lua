-- lib/type/v10_kernel/pilot/narrow_persist_v1.lua
--
-- Corroboration proof-of-concept, spine step 3 — WIRING COMPOSITION:
-- narrowing's rules consume the effects spine's `preserves` judgment
-- (pilot/effects_spine_v1.lua) as an ordinary premise, deriving narrowings
-- neither theory reaches alone. Declared over the canonical v10 core
-- (lib/type/v10_cleanroom/, per the owner-ratified canon swap).
--
-- fable-delegation-tier throughout (per the core design's pilot-execution
-- delegation note): every choice here is a delegated-execution decision,
-- re-openable on challenge, not an owner ratification.
--
-- ── No new vocabulary — this module declares ONE RULE, no signature ────────
--
-- Unlike every other pilot theory module in this directory, this file calls
-- `declare_signature` NOWHERE. `declare_rule`
-- (lib/type/v10_cleanroom/replayer.lua) takes plain premise/conclusion
-- TERMS, not a signature — a rule schema is a registry object, scoped by
-- (name, version), never scoped to any one signature. The new rule below
-- therefore needs no new operator and no version bump of narrow-pilot-v1:
-- it cites `holds_at` from an ALREADY-DECLARED narrow_pilot_v1 (or
-- flow_narrow_v1) vocabulary's own `HoldsAt` builder, unmodified, plus
-- `preserves` from an ALREADY-DECLARED effects spine's own `Preserves`
-- builder, unmodified. Narrowing's own signature object is never touched;
-- the spine's signature object is never touched. This is the literal
-- "consume spine judgments as ordinary premises" instruction — composition
-- lives entirely at the RULE layer, leaving both theories' vocabularies
-- exactly as independently authored.
--
-- Sort compatibility falls out of shared addressing, not a special case:
-- narrowing's `holds_at`'s first argument and the spine's `preserves`'s
-- first two arguments are both sort `point` — but ONLY because narrowing's
-- own signature and the spine signature both IMPORTED `point` from the
-- SAME addr-v1 signature object (sort identity = declared-object identity,
-- per the core design's sort-identity ratification). A metavariable typed
-- against that one shared addr-v1 `point` object is simultaneously
-- well-sorted in both operators' patterns — the mechanism that makes one
-- rule able to mix operators from two independently-declared signatures at
-- all, with no bridge/adapter vocabulary of its own.
--
-- ── The rule: `narrow-persist` ──────────────────────────────────────────────
--
--   narrow-persist : holds_at(P,X,T), preserves(P,Q,X) |- holds_at(Q,X,T)
--
-- "If X's type is known at P, and X's binding is known (by ANY spine
-- producer) to survive unchanged from P to Q, then X's type is ALSO known
-- at Q." `P`/`Q` are point metavariables, `X` a path metavariable, `T` a
-- narrowing-owned `ty` metavariable (from narrow-pilot-v1's own `ty` sort —
-- untouched by, and invisible to, the effects spine or any effects theory).
-- No side condition was needed — HALT was not triggered.

local ta = require("lib.type.v10_cleanroom.term_algebra")
local replayer = require("lib.type.v10_cleanroom.replayer")

local M = {}

--:: NarrowPersist = { rule_persist: RuleDecl }

-- Declare `narrow-persist` (v1) into the given registry, citing an
-- already-declared narrowing vocabulary's `HoldsAt`/signature (as returned
-- by flow_narrow_v1.declare_vocabulary or narrow_pilot_v1.declare + a
-- HoldsAt builder over it) and an already-declared effects spine's
-- `Preserves`/signature (effects_spine_v1.declare's return value). Caps-clean:
-- all three are injected, never reached for ambiently.
-- `narrow_vocab`/`spine` are typed `unknown` and narrowed by hand: the same
-- typechecker gotcha every other pilot module in this directory documents.
--: (registry: Registry, narrow_vocab: unknown, spine: unknown) -> (NarrowPersist | nil, string | nil)
function M.declare(registry, narrow_vocab, spine)
	if type(narrow_vocab) ~= "table" then
		return nil, "declare: narrow_vocab (a declared narrowing vocabulary) is required"
	end
	local nv = narrow_vocab --[[: { signature: Signature, HoldsAt: (p: Term, x: Term, ty: Term) -> (Term | nil, string | nil) } ]]
	local narrow_sig = nv.signature
	if type(narrow_sig) ~= "table" or type(nv.HoldsAt) ~= "function" then
		return nil, "declare: narrow_vocab must carry a signature and a HoldsAt builder"
	end
	local narrow_sig_t = narrow_sig --[[: Signature ]]
	if type(spine) ~= "table" then
		return nil, "declare: spine (a declared effects_spine_v1 spine) is required"
	end
	local sp = spine --[[: { signature: Signature, Preserves: (from: Term, to: Term, x: Term) -> (Term | nil, string | nil) } ]]
	if type(sp.signature) ~= "table" or type(sp.Preserves) ~= "function" then
		return nil, "declare: spine must be effects_spine_v1.declare's return value"
	end
	-- Structural compatibility check (not merely defensive): narrowing's own
	-- point sort and the spine's point sort must be the SAME declared
	-- object, or the rule below could never be well-sorted to begin with —
	-- surfacing a mismatched-addressing-signature setup as a clear error
	-- here rather than an opaque `declare_rule` failure below.
	if narrow_sig_t.sorts.point ~= sp.signature.sorts.point then
		return nil, "declare: narrow_vocab and spine were declared over DIFFERENT addr-v1 point sorts "
			.. "(both must import point/path from the SAME addr-v1 signature object)"
	end
	if narrow_sig_t.sorts.path ~= sp.signature.sorts.path then
		return nil, "declare: narrow_vocab and spine were declared over DIFFERENT addr-v1 path sorts "
			.. "(both must import point/path from the SAME addr-v1 signature object)"
	end

	local p = ta.meta("P", narrow_sig_t.sorts.point)
	local q = ta.meta("Q", narrow_sig_t.sorts.point)
	local x = ta.meta("X", narrow_sig_t.sorts.path)
	local t = ta.meta("T", narrow_sig_t.sorts.ty)
	if not p or not q or not x or not t then
		return nil, "declare: failed to build shared metavariables"
	end

	local holds_p = nv.HoldsAt(p, x, t)
	local holds_q = nv.HoldsAt(q, x, t)
	local pres_pq = sp.Preserves(p, q, x)
	if not holds_p or not holds_q or not pres_pq then
		return nil, "declare: failed to build narrow-persist patterns"
	end

	local rule_persist, err = replayer.declare_rule(registry, {
		name = "narrow-persist", version = 1,
		premises = { holds_p, pres_pq },
		conclusion = holds_q,
	})
	if not rule_persist then return nil, err end

	return { rule_persist = rule_persist }
end

return M
