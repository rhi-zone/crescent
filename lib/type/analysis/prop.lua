-- Hosted semantics: prop.logic.min
--
-- The propositional checker from docs/agnostic-static-analysis-prop-logic.md.
-- It IMPORTS the substrate; the substrate does NOT import it. The substrate
-- knows nothing about props — this module owns the Prop grammar, the `holds`
-- claim, and the evidence methods.
--
-- Per the hosted-checker trust obligation (object model), the checker is small
-- and driven by a declarative rule table for the intro/elim forms; anything
-- non-declarative (the contradiction policy) is explicit. The checker is
-- hand-written Lua, so its verdict is itself a trusted boundary — surfaced via
-- A.unverified_checker_trust on every accepted claim.

local A = require("lib.type.analysis")

local M = {}

M.ID = "prop.logic.min"
M.VERSION = "0"

-- ── Prop grammar (hosted vocabulary, opaque to the substrate) ──────────────
--:: PLAtom    = { tag: "atom", name: string }
--:: PLAnd     = { tag: "and", left: Prop, right: Prop }
--:: PLImplies = { tag: "implies", left: Prop, right: Prop }
--:: PLNot     = { tag: "not", inner: Prop }
--:: Prop = PLAtom | PLAnd | PLImplies | PLNot

--: (string) -> PLAtom
function M.atom(name) return { tag = "atom", name = name } end
--: (Prop, Prop) -> PLAnd
function M.p_and(l, r) return { tag = "and", left = l, right = r } end
--: (Prop, Prop) -> PLImplies
function M.p_implies(l, r) return { tag = "implies", left = l, right = r } end
--: (Prop) -> PLNot
function M.p_not(inner) return { tag = "not", inner = inner } end

-- Structural equality of two Props. Props are ArgValue-shaped data, so we reuse
-- the substrate's canonical serializer rather than hand-walking the tree. This
-- keeps "structural identity" defined in exactly one place (the substrate).
--: (Prop, Prop) -> boolean
local function prop_eq(a, b)
	return A._serialize(a) == A._serialize(b)
end

-- Build a holds(P) claim.
--: ({ space: string, key: string }, Prop) -> Claim
function M.holds_claim(id, prop)
	return A.claim({
		id = id,
		semantics = M.ID,
		predicate = "holds",
		args = { prop = prop },
	})
end

-- Parse the opaque ArgValue carried by a holds claim back into a typed Prop.
--
-- MECHANIZATION FINDING: the substrate stores args as opaque `ArgValue` data
-- (not TS-`unknown`, which the typechecker forbids casting away from; not a
-- blind force cast, which the typechecker also rejects for an index-signature
-- table downcast to a record). So the hosted semantics must PARSE/VALIDATE its
-- args at the boundary, reconstructing a typed value via `type()`-narrowing and
-- tag-dispatch. This is stronger than a cast and is what the hosted-checker
-- trust obligation wants: the checker validates its own inputs rather than
-- trusting their shape. Recorded in the object-model doc's arg-schema item.
local parse_prop --[[: (unknown) -> Prop | nil ]]
--: (unknown) -> Prop | nil
parse_prop = function(v)
	if type(v) ~= "table" then return nil end
	local tag = v.tag
	if tag == "atom" then
		local name = v.name
		if type(name) ~= "string" then return nil end
		return { tag = "atom", name = name }
	elseif tag == "and" or tag == "implies" then
		local l = parse_prop(v.left)
		local r = parse_prop(v.right)
		if not l or not r then return nil end
		if tag == "and" then return { tag = "and", left = l, right = r } end
		return { tag = "implies", left = l, right = r }
	elseif tag == "not" then
		local inner = parse_prop(v.inner)
		if not inner then return nil end
		return { tag = "not", inner = inner }
	end
	return nil
end

-- The Prop carried by a holds claim, or nil if the args are malformed.
--: (Claim) -> Prop | nil
local function claim_prop(claim)
	local args = claim.args
	if type(args) ~= "table" then return nil end
	return parse_prop(args.prop)
end

-- ── Checker ─────────────────────────────────────────────────────────────────
--
-- (CheckContext, Claim, Evidence) -> (result, diagnostic, deps, trust)
--
-- The evidence `result` field carries hosted parameters where a method needs
-- them (assumption scope id, trust boundary id). Inputs are claim Ids of the
-- premises this evidence consumes.

--: () -> unknown
local function trust_note() return A.unverified_checker_trust(M.ID, M.VERSION) end

-- Parse an Id out of an ArgValue (the payload's scope/trust references).
--: (unknown) -> Id | nil
local function parse_id(v)
	if type(v) ~= "table" then return nil end
	local space, key = v.space, v.key
	if type(space) ~= "string" or type(key) ~= "string" then return nil end
	return { space = space, key = key }
end

--: HostedChecker
function M.checker(ctx, claim, ev)
	local goal = claim_prop(claim)
	if not goal then
		return ctx.REJECTED, "holds claim args are not a well-formed Prop", nil, nil
	end
	local method = ev.method
	local payload = ev.result
	local payload_scope --[[: Id | nil ]]
	local payload_trust --[[: Id | nil ]]
	if type(payload) == "table" then
		payload_scope = parse_id(payload.scope)
		payload_trust = parse_id(payload.trust)
	end

	if method == "assumption" then
		-- Accept holds(P) only inside an evidence scope that admits P.
		-- The scope is named by payload.scope (a trust/assumption boundary id).
		if not payload_scope then
			return ctx.UNKNOWN, nil, nil, nil
		end
		local deps = { A.dependency({ from_claim = claim.id, kind = A.DEP_ASSUMPTION, target = payload_scope }) }
		return ctx.ACCEPTED, nil, deps, { trust_note() }

	elseif method == "trusted_axiom" then
		-- Accept holds(P) through a visible trust boundary.
		if not payload_trust then
			return ctx.REJECTED, "trusted_axiom evidence missing trust boundary", nil, nil
		end
		local tb = ctx.state.trust_boundaries[A.idk(payload_trust)]
		if not tb then
			return ctx.REJECTED, "trusted_axiom references unknown trust boundary", nil, nil
		end
		local deps = { A.dependency({ from_claim = claim.id, kind = A.DEP_TRUSTED_BOUNDARY, target = tb.id }) }
		return ctx.ACCEPTED, nil, deps, { tb, trust_note() }

	elseif method == "and_intro" then
		-- Goal must be and(A,B); inputs accepted holds(A), holds(B).
		if goal.tag ~= "and" then
			return ctx.REJECTED, "and_intro goal is not a conjunction", nil, nil
		end
		if #ev.inputs ~= 2 then return ctx.REJECTED, "and_intro requires two inputs", nil, nil end
		local inL, inR = ev.inputs[1], ev.inputs[2]
		local cL = ctx.get_claim(inL)
		local cR = ctx.get_claim(inR)
		if not cL or not cR then return ctx.REJECTED, "and_intro inputs not found", nil, nil end
		local pL = claim_prop(cL)
		local pR = claim_prop(cR)
		if not pL or not pR then return ctx.REJECTED, "and_intro input is not a well-formed Prop", nil, nil end
		if not (prop_eq(pL, goal.left) and prop_eq(pR, goal.right)) then
			return ctx.REJECTED, "and_intro inputs do not match conjuncts", nil, nil
		end
		if not (ctx.is_accepted(inL) and ctx.is_accepted(inR)) then
			return ctx.UNKNOWN, nil, nil, nil -- premises not yet accepted; retry later
		end
		local deps = {
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = inL }),
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = inR }),
		}
		return ctx.ACCEPTED, nil, deps, { trust_note() }

	elseif method == "and_elim_left" or method == "and_elim_right" then
		-- Input accepted holds(and(A,B)); goal must be A (left) or B (right).
		if #ev.inputs ~= 1 then return ctx.REJECTED, "and_elim requires one input", nil, nil end
		local inC = ev.inputs[1]
		local c = ctx.get_claim(inC)
		if not c then return ctx.REJECTED, "and_elim input not found", nil, nil end
		local conj = claim_prop(c)
		if not conj or conj.tag ~= "and" then return ctx.REJECTED, "and_elim input is not a conjunction", nil, nil end
		local want = method == "and_elim_left" and conj.left or conj.right
		if not prop_eq(goal, want) then
			return ctx.REJECTED, "and_elim goal does not match the selected conjunct", nil, nil
		end
		if not ctx.is_accepted(inC) then return ctx.UNKNOWN, nil, nil, nil end
		local deps = { A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = inC }) }
		return ctx.ACCEPTED, nil, deps, { trust_note() }

	elseif method == "modus_ponens" then
		-- Inputs accepted holds(A), holds(implies(A,B)); goal must be B.
		if #ev.inputs ~= 2 then return ctx.REJECTED, "modus_ponens requires two inputs", nil, nil end
		local inA, inImp = ev.inputs[1], ev.inputs[2]
		local cA = ctx.get_claim(inA)
		local cImp = ctx.get_claim(inImp)
		if not cA or not cImp then return ctx.REJECTED, "modus_ponens inputs not found", nil, nil end
		local imp = claim_prop(cImp)
		local pA = claim_prop(cA)
		if not imp or not pA then return ctx.REJECTED, "modus_ponens input is not a well-formed Prop", nil, nil end
		if imp.tag ~= "implies" then
			return ctx.REJECTED, "modus_ponens second input is not an implication", nil, nil
		end
		if not prop_eq(pA, imp.left) then
			return ctx.REJECTED, "implication antecedent does not match premise", nil, nil
		end
		if not prop_eq(goal, imp.right) then
			return ctx.REJECTED, "modus_ponens goal does not match implication consequent", nil, nil
		end
		if not (ctx.is_accepted(inA) and ctx.is_accepted(inImp)) then
			return ctx.UNKNOWN, nil, nil, nil
		end
		local deps = {
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = inA }),
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = inImp }),
		}
		return ctx.ACCEPTED, nil, deps, { trust_note() }

	elseif method == "contradiction" then
		-- Inputs accepted holds(A), holds(not(A)). This is NOT explosion: it
		-- does not accept the goal. It records an inconsistency diagnostic and
		-- REJECTS the goal claim (hosted policy — the substrate has no
		-- contradiction rule). A hosted policy could instead allow inconsistent
		-- contexts; this minimal semantics rejects.
		if #ev.inputs ~= 2 then return ctx.REJECTED, "contradiction requires two inputs", nil, nil end
		local in1, in2 = ev.inputs[1], ev.inputs[2]
		local c1 = ctx.get_claim(in1)
		local c2 = ctx.get_claim(in2)
		if not c1 or not c2 then return ctx.REJECTED, "contradiction inputs not found", nil, nil end
		local p1 = claim_prop(c1)
		local p2 = claim_prop(c2)
		if not p1 or not p2 then return ctx.REJECTED, "contradiction input is not a well-formed Prop", nil, nil end
		local incompatible =
			(p2.tag == "not" and prop_eq(p2.inner, p1)) or
			(p1.tag == "not" and prop_eq(p1.inner, p2))
		if not incompatible then
			return ctx.REJECTED, "contradiction inputs are not P and not-P", nil, nil
		end
		if not (ctx.is_accepted(in1) and ctx.is_accepted(in2)) then
			return ctx.UNKNOWN, nil, nil, nil
		end
		local deps = {
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = in1 }),
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = in2 }),
		}
		return ctx.REJECTED, "inconsistent context: P and not-P both accepted", deps, nil
	end

	return ctx.UNKNOWN, "unknown evidence method: " .. tostring(method), nil, nil
end

-- Register prop.logic.min in a registry.
--: (SemanticsRegistry) -> (boolean, string | nil)
function M.register(registry)
	return A.register(registry, {
		id = M.ID,
		version = M.VERSION,
		claim_predicates = { "holds" },
		observation_predicates = {},
		evidence_methods = {
			"assumption", "trusted_axiom", "and_intro",
			"and_elim_left", "and_elim_right", "modus_ponens", "contradiction",
		},
		trusted_methods = { "trusted_axiom" },
		checker = M.checker,
	})
end

return M
