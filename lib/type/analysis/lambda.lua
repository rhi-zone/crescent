-- Hosted semantics: lambda.untyped.min
--
-- The untyped-lambda checker from docs/agnostic-static-analysis-lambda.md. It
-- IMPORTS the substrate; the substrate does NOT import it. The substrate knows
-- nothing about terms, binders, alpha-equivalence, or substitution — this
-- module owns all of it, and its internal representation (here: source-named
-- terms with a fresh-variable supply) is EVIDENCE-LOCAL. The substrate stores
-- only opaque term shapes (as ArgValue) and the claims/evidence/dependencies.
--
-- Beta is call-by-name at the OUTERMOST redex only — no congruence (deliberately
-- absent per the doc; congruence waits for a later pass that specifies
-- evaluation contexts).
--
-- The hosted checker is hand-written Lua, so its verdict is itself a trusted
-- boundary, surfaced via A.unverified_checker_trust on every accepted claim.

local A = require("lib.type.analysis")

local M = {}

M.ID = "lambda.untyped.min"
M.VERSION = "0"

-- ── Term grammar (hosted vocabulary, opaque to the substrate) ──────────────
--:: LamVar = { tag: "var", name: string }
--:: LamLam = { tag: "lam", param: string, body: LamTerm }
--:: LamApp = { tag: "app", fn: LamTerm, arg: LamTerm }
--:: LamTerm = LamVar | LamLam | LamApp

--: (string) -> LamVar
function M.var(name) return { tag = "var", name = name } end
--: (string, LamTerm) -> LamLam
function M.lam(param, body) return { tag = "lam", param = param, body = body } end
--: (LamTerm, LamTerm) -> LamApp
function M.app(fn, arg) return { tag = "app", fn = fn, arg = arg } end

-- Parse an opaque ArgValue back into a typed LamTerm (see prop.lua's parse_prop
-- finding: the hosted checker VALIDATES its args at the boundary rather than
-- casting; this is what the trust obligation wants).
local parse_term --[[: (unknown) -> LamTerm | nil ]]
--: (unknown) -> LamTerm | nil
parse_term = function(v)
	if type(v) ~= "table" then return nil end
	local tag = v.tag
	if tag == "var" then
		local name = v.name
		if type(name) ~= "string" then return nil end
		return { tag = "var", name = name }
	elseif tag == "lam" then
		local param = v.param
		if type(param) ~= "string" then return nil end
		local body = parse_term(v.body)
		if not body then return nil end
		return { tag = "lam", param = param, body = body }
	elseif tag == "app" then
		local fn = parse_term(v.fn)
		local arg = parse_term(v.arg)
		if not fn or not arg then return nil end
		return { tag = "app", fn = fn, arg = arg }
	end
	return nil
end

M.parse_term = parse_term

-- ── Term operations (all EVIDENCE-LOCAL hosted vocabulary) ─────────────────

-- Structural (NOT alpha) equality of terms, via the substrate serializer.
--: (LamTerm, LamTerm) -> boolean
local function term_eq(a, b)
	return A._serialize(a) == A._serialize(b)
end

-- Free-variable membership: does `name` occur free in `t`?
local free_in --[[: (string, LamTerm) -> boolean ]]
--: (string, LamTerm) -> boolean
free_in = function(name, t)
	if t.tag == "var" then return t.name == name end
	if t.tag == "lam" then
		if t.param == name then return false end -- bound, shadowed
		return free_in(name, t.body)
	end
	-- app
	return free_in(name, t.fn) or free_in(name, t.arg)
end

M.free_in = free_in

-- Collect the set of free variable names in a term.
local free_vars
--: (LamTerm, { [string]: boolean | nil }) -> nil
free_vars = function(t, acc)
	if t.tag == "var" then acc[t.name] = true; return end
	if t.tag == "lam" then
		local was = acc[t.param] == true
		free_vars(t.body, acc)
		if not was then acc[t.param] = nil end -- remove if it was bound here
		return
	end
	free_vars(t.fn, acc)
	free_vars(t.arg, acc)
end

-- Alpha-normal form: rename every bound variable to a canonical positional name
-- (#0, #1, ...) by binder depth. Two terms are alpha-equal iff their normal
-- forms are structurally equal. This is the EVIDENCE-LOCAL representation the
-- doc allows; the substrate never sees it.
local anf
--: (LamTerm, { [string]: { [integer]: string } }, integer) -> LamTerm
anf = function(t, env, depth)
	if t.tag == "var" then
		local stack = env[t.name]
		if stack and #stack > 0 then
			return { tag = "var", name = stack[#stack] }
		end
		-- free variable: keep its source name (free names are significant for
		-- alpha-equivalence).
		return { tag = "var", name = t.name }
	end
	if t.tag == "lam" then
		local canon = "#" .. tostring(depth)
		local stack = env[t.param] or {}
		stack[#stack + 1] = canon
		env[t.param] = stack
		local body = anf(t.body, env, depth + 1)
		stack[#stack] = nil
		return { tag = "lam", param = canon, body = body }
	end
	return { tag = "app", fn = anf(t.fn, env, depth), arg = anf(t.arg, env, depth) }
end

--: (LamTerm) -> LamTerm
local function alpha_normal(t)
	return anf(t, {}, 0)
end

M.alpha_normal = alpha_normal

--: (LamTerm, LamTerm) -> boolean
local function alpha_eq(a, b)
	return term_eq(alpha_normal(a), alpha_normal(b))
end

M.alpha_eq = alpha_eq

-- ── Claim builders ──────────────────────────────────────────────────────────

--: ({ space: string, key: string }, Id) -> Claim
function M.well_formed_claim(id, term_ref)
	return A.claim({ id = id, semantics = M.ID, predicate = "well_formed", args = { term = { space = term_ref.space, key = term_ref.key } } })
end

--: ({ space: string, key: string }, Id, Id) -> Claim
function M.alpha_eq_claim(id, left_ref, right_ref)
	return A.claim({ id = id, semantics = M.ID, predicate = "alpha_eq",
		args = { left = { space = left_ref.space, key = left_ref.key }, right = { space = right_ref.space, key = right_ref.key } } })
end

--: ({ space: string, key: string }, string, Id) -> Claim
function M.free_in_claim(id, name, term_ref)
	return A.claim({ id = id, semantics = M.ID, predicate = "free_in", args = { name = name, term = { space = term_ref.space, key = term_ref.key } } })
end

--: ({ space: string, key: string }, string, Id) -> Claim
function M.not_free_in_claim(id, name, term_ref)
	return A.claim({ id = id, semantics = M.ID, predicate = "not_free_in", args = { name = name, term = { space = term_ref.space, key = term_ref.key } } })
end

--: ({ space: string, key: string }, Id, Id) -> Claim
function M.steps_to_claim(id, source_ref, target_ref)
	return A.claim({ id = id, semantics = M.ID, predicate = "steps_to",
		args = { source = { space = source_ref.space, key = source_ref.key }, target = { space = target_ref.space, key = target_ref.key } } })
end

-- ── Helpers to read claim args / artifact terms ────────────────────────────

--: (unknown) -> Id | nil
local function arg_id(v)
	if type(v) ~= "table" then return nil end
	local space, key = v.space, v.key
	if type(space) ~= "string" or type(key) ~= "string" then return nil end
	return { space = space, key = key }
end

-- Read the LamTerm content of an artifact referenced by Id, or nil.
--: (CheckContext, Id) -> LamTerm | nil
local function term_of(ctx, ref)
	local art = ctx.get_artifact(ref)
	if not art then return nil end
	return parse_term(art.content_ref)
end

-- ── Capture-avoiding substitution (EVIDENCE-LOCAL) ─────────────────────────
--
-- substitute(body, x, arg): replace free occurrences of `x` in `body` with
-- `arg`, alpha-renaming binders that would capture a free variable of `arg`.
-- The checker uses a fresh-name supply derived from a "y" -> "y1" scheme so the
-- doc's expected `y1` result is produced deterministically.
local substitute

-- Pick a fresh name not free in `avoid` and not equal to any name in `taken`.
--: (string, { [string]: boolean }) -> string
local function fresh(base, taken)
	local cand = base .. "1"
	local i = 1
	while taken[cand] do
		i = i + 1
		cand = base .. tostring(i)
	end
	return cand
end

--: (LamTerm, string, LamTerm) -> LamTerm
substitute = function(body, x, arg)
	if body.tag == "var" then
		if body.name == x then return arg end
		return { tag = "var", name = body.name }
	end
	if body.tag == "lam" then
		if body.param == x then
			-- x is rebound; no substitution inside.
			return { tag = "lam", param = body.param, body = body.body }
		end
		-- Capture check: if the binder's name is free in arg, rename it.
		if free_in(body.param, arg) then
			-- gather names to avoid: free vars of arg + free vars of body
			local taken = {} --[[: { [string]: boolean } ]]
			free_vars(arg, taken)
			free_vars(body.body, taken)
			taken[x] = true
			local fresh_name = fresh(body.param, taken)
			local renamed_body = substitute(body.body, body.param, { tag = "var", name = fresh_name })
			return { tag = "lam", param = fresh_name, body = substitute(renamed_body, x, arg) }
		end
		return { tag = "lam", param = body.param, body = substitute(body.body, x, arg) }
	end
	return { tag = "app", fn = substitute(body.fn, x, arg), arg = substitute(body.arg, x, arg) }
end

M.substitute = substitute

-- One outermost call-by-name beta step, or nil if no redex at the root.
--: (LamTerm) -> LamTerm | nil
local function beta_outermost(t)
	if t.tag == "app" and t.fn.tag == "lam" then
		return substitute(t.fn.body, t.fn.param, t.arg)
	end
	return nil
end

M.beta_outermost = beta_outermost

-- For the pinned beta_step contract: the set of names that occur free in `arg`
-- AND are bound by a lambda the substitution descends under (i.e. would be
-- captured without renaming). The checker requires an accepted not_free_in (or,
-- per the doc's capture example, consumes a free_in establishing the collision)
-- discharge for these. We compute the colliding binder names.
--: (LamTerm, string, LamTerm) -> { [integer]: string }
local function capture_binders(body, x, arg)
	local out = {} --[[: { [integer]: string } ]]
	local seen = {} --[[: { [string]: boolean } ]]
	local walk
	--: (LamTerm) -> nil
	walk = function(t)
		if t.tag == "var" then return end
		if t.tag == "lam" then
			if t.param == x then return end -- x rebound; substitution stops here
			-- This binder would capture a free var of arg, and substitution
			-- actually reaches it (x occurs free under it), iff:
			if free_in(t.param, arg) and free_in(x, t.body) then
				if not seen[t.param] then
					seen[t.param] = true
					out[#out + 1] = t.param
				end
			end
			walk(t.body)
			return
		end
		walk(t.fn)
		walk(t.arg)
	end
	walk(body)
	return out
end

M.capture_binders = capture_binders

-- ── Checker ─────────────────────────────────────────────────────────────────

--: () -> unknown
local function trust_note() return A.unverified_checker_trust(M.ID, M.VERSION) end

--: HostedChecker
function M.checker(ctx, claim, ev)
	local method = ev.method
	local args = claim.args
	if type(args) ~= "table" then
		return ctx.REJECTED, "claim args are not a table", nil, nil
	end

	local predicate = claim.predicate
	if predicate == "well_formed" then
		-- artifact_shape_check or trusted_term.
		local ref = arg_id(args.term)
		if not ref then return ctx.REJECTED, "well_formed missing term ref", nil, nil end
		if method == "trusted_term" then
			-- Accept through a visible trust boundary named in the result.
			local payload = ev.result
			local tb_id = type(payload) == "table" and arg_id(payload.trust) or nil
			if not tb_id then return ctx.REJECTED, "trusted_term missing trust boundary", nil, nil end
			local tb = ctx.state.trust_boundaries[A.idk(tb_id)]
			if not tb then return ctx.REJECTED, "trusted_term references unknown trust boundary", nil, nil end
			local deps = { A.dependency({ from_claim = claim.id, kind = A.DEP_TRUSTED_BOUNDARY, target = tb.id }) }
			return ctx.ACCEPTED, nil, deps, { tb, trust_note() }
		elseif method == "artifact_shape_check" then
			local term = term_of(ctx, ref)
			if not term then return ctx.REJECTED, "term artifact is malformed lambda syntax", nil, nil end
			local deps = { A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = ref }) }
			return ctx.ACCEPTED, nil, deps, { trust_note() }
		end
		return ctx.UNKNOWN, "unknown well_formed method: " .. tostring(method), nil, nil

	elseif predicate == "alpha_eq" then
		if method ~= "alpha_normal_form" then
			return ctx.UNKNOWN, "unknown alpha_eq method: " .. tostring(method), nil, nil
		end
		local lref = arg_id(args.left)
		local rref = arg_id(args.right)
		if not lref or not rref then return ctx.REJECTED, "alpha_eq missing term refs", nil, nil end
		-- Requires accepted well_formed(left) and well_formed(right).
		if #ev.inputs ~= 2 then return ctx.REJECTED, "alpha_normal_form requires two well_formed inputs", nil, nil end
		if not (ctx.is_accepted(ev.inputs[1]) and ctx.is_accepted(ev.inputs[2])) then
			return ctx.UNKNOWN, nil, nil, nil
		end
		local lt = term_of(ctx, lref)
		local rt = term_of(ctx, rref)
		if not lt or not rt then return ctx.REJECTED, "alpha_eq term artifact malformed", nil, nil end
		if not alpha_eq(lt, rt) then
			return ctx.REJECTED, "terms are not alpha-equivalent", nil, nil
		end
		local deps = {
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = ev.inputs[1] }),
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = ev.inputs[2] }),
			A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = lref }),
			A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = rref }),
		}
		return ctx.ACCEPTED, nil, deps, { trust_note() }

	elseif predicate == "free_in" or predicate == "not_free_in" then
		if method ~= "free_var_scan" then
			return ctx.UNKNOWN, "unknown free-var method: " .. tostring(method), nil, nil
		end
		local name = args.name
		local ref = arg_id(args.term)
		if type(name) ~= "string" or not ref then return ctx.REJECTED, "free-var claim malformed", nil, nil end
		-- Requires accepted well_formed(term).
		if #ev.inputs ~= 1 then return ctx.REJECTED, "free_var_scan requires one well_formed input", nil, nil end
		if not ctx.is_accepted(ev.inputs[1]) then return ctx.UNKNOWN, nil, nil, nil end
		local term = term_of(ctx, ref)
		if not term then return ctx.REJECTED, "free-var term artifact malformed", nil, nil end
		local is_free = free_in(name, term)
		local want_free = claim.predicate == "free_in"
		if is_free ~= want_free then
			return ctx.REJECTED, "free-variable scan contradicts the claim", nil, nil
		end
		local deps = {
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = ev.inputs[1] }),
			A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = ref }),
		}
		return ctx.ACCEPTED, nil, deps, { trust_note() }

	elseif predicate == "steps_to" then
		if method ~= "beta_step" then
			return ctx.UNKNOWN, "unknown steps_to method: " .. tostring(method), nil, nil
		end
		local sref = arg_id(args.source)
		local tref = arg_id(args.target)
		if not sref or not tref then return ctx.REJECTED, "steps_to missing term refs", nil, nil end
		-- Inputs: well_formed(source), well_formed(target), and the pinned
		-- not_free_in / free_in claims required for capture avoidance. The
		-- substrate finds an acceptance order; we require the two well_formed
		-- inputs accepted, then check the beta result, then verify the pinned
		-- capture-avoidance dependency is among the accepted inputs.
		if #ev.inputs < 2 then return ctx.REJECTED, "beta_step requires at least two well_formed inputs", nil, nil end
		local src_wf = ev.inputs[1]
		local tgt_wf = ev.inputs[2]
		if not (ctx.is_accepted(src_wf) and ctx.is_accepted(tgt_wf)) then
			return ctx.UNKNOWN, nil, nil, nil
		end
		local source = term_of(ctx, sref)
		local target = term_of(ctx, tref)
		if not source or not target then return ctx.REJECTED, "beta_step term artifact malformed", nil, nil end
		if source.tag ~= "app" then
			return ctx.REJECTED, "beta_step source has no outermost redex", nil, nil
		end
		local fn = source.fn
		local arg = source.arg
		if fn.tag ~= "lam" then
			return ctx.REJECTED, "beta_step source has no outermost redex", nil, nil
		end
		-- Pinned contract: for every name free in the argument that is bound by
		-- a lambda the substitution descends under (i.e. would be captured),
		-- require an accepted free-variable discharge among the EXTRA inputs.
		-- Capture avoidance is thereby a checkable CROSS-EVIDENCE dependency,
		-- produced by a separate free_var_scan, not hidden in the substitution.
		local colliders = capture_binders(fn.body, fn.param, arg)
		local extra_deps = {} --[[: { [integer]: Dependency } ]]
		for _, cname in ipairs(colliders) do
			-- Find an input claim that establishes the collision: free_in(cname,
			-- arg). Distinguish three cases so scheduling stays order-independent:
			--   present + accepted  -> discharged
			--   present, not yet accepted -> UNKNOWN (retry next sweep)
			--   absent entirely     -> REJECTED (contract not satisfiable)
			local discharged = false
			local pending = false
			for i = 3, #ev.inputs do
				local inp = ev.inputs[i]
				local ic = ctx.get_claim(inp)
				if ic and ic.predicate == "free_in" then
					local ia = ic.args
					if type(ia) == "table" and ia.name == cname then
						if ctx.is_accepted(inp) then
							discharged = true
							extra_deps[#extra_deps + 1] =
								A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = inp })
						else
							pending = true
						end
					end
				end
			end
			if not discharged and pending then
				return ctx.UNKNOWN, nil, nil, nil -- discharge input exists but not yet accepted
			end
			if not discharged then
				return ctx.REJECTED,
					"beta_step capture-avoidance side condition not discharged for binder " .. cname, nil, nil
			end
		end
		-- Compute the capture-avoiding beta result and compare with target.
		local result = beta_outermost(source)
		if not result then return ctx.REJECTED, "beta_step found no redex to reduce", nil, nil end
		if not alpha_eq(result, target) then
			return ctx.REJECTED, "beta_step target does not match the substitution result", nil, nil
		end
		local deps = {
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = src_wf }),
			A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = tgt_wf }),
			A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = sref }),
			A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = tref }),
		}
		for _, d in ipairs(extra_deps) do deps[#deps + 1] = d end
		return ctx.ACCEPTED, nil, deps, { trust_note() }
	end

	return ctx.REJECTED, "unknown claim predicate: " .. tostring(claim.predicate), nil, nil
end

-- Register lambda.untyped.min in a registry.
--: (SemanticsRegistry) -> (boolean, string | nil)
function M.register(registry)
	return A.register(registry, {
		id = M.ID,
		version = M.VERSION,
		claim_predicates = { "well_formed", "alpha_eq", "free_in", "not_free_in", "steps_to" },
		observation_predicates = { "term_shape" },
		evidence_methods = {
			"artifact_shape_check", "alpha_normal_form", "free_var_scan",
			"beta_step", "trusted_term",
		},
		trusted_methods = { "trusted_term" },
		checker = M.checker,
	})
end

return M
