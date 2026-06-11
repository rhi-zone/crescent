-- Hosted semantics: stlc.min
--
-- Simply typed lambda calculus as a hosted semantics, validating ladder rung 4
-- (docs/agnostic-static-analysis-stlc.md). It IMPORTS the substrate; the
-- substrate does NOT import it. The substrate learns NOTHING new: no Type, no
-- Context, no Judgment object kind. Types and typing contexts are hosted data
-- carried inside claim args (ArgValue), exactly like LamTerm shapes in
-- lambda.lua. The abstraction rule's context extension (Γ,x:A) is a hosted
-- operation on that data, never a substrate primitive.
--
-- Typing rules (var/abs/app) are evidence methods. abs and app consume
-- previously-accepted has_type claims as inputs, so this is the first rung where
-- evidence trees get genuinely deep (a two-level derivation: app over two
-- has_type premises, one of which is itself an abs over a has_type premise).
--
-- The hosted checker is hand-written Lua, so its verdict is itself a trusted
-- boundary, surfaced via A.unverified_checker_trust on every accepted claim.
--
-- Errors are returned as (nil, errmsg) / a rejected result class; the checker
-- never throws for data errors.

local A = require("lib.type.analysis")

local M = {}

M.ID = "stlc.min"
M.VERSION = "0"

-- ── Type grammar (hosted vocabulary, opaque to the substrate) ──────────────
-- A Type is a base type or an arrow. This grammar lives only here and inside
-- claim args as ArgValue. The substrate compares it structurally; it does not
-- know `arrow` means "function" or that `base` is atomic.
--:: TyBase = { tag: "base", name: string }
--:: TyArrow = { tag: "arrow", from: Type, to: Type }
--:: Type = TyBase | TyArrow

--: (string) -> TyBase
function M.base(name) return { tag = "base", name = name } end
--: (Type, Type) -> TyArrow
function M.arrow(from, to) return { tag = "arrow", from = from, to = to } end

-- ── Term grammar (hosted vocabulary, opaque to the substrate) ──────────────
-- STLC abstractions are type-annotated: lam binds `param` with declared type
-- `paramType`. var and app match the untyped grammar. Stored in artifacts and
-- referenced by Id, as in lambda.lua.
--:: StTmVar = { tag: "var", name: string }
--:: StTmLam = { tag: "lam", param: string, paramType: Type, body: StTerm }
--:: StTmApp = { tag: "app", fn: StTerm, arg: StTerm }
--:: StTerm = StTmVar | StTmLam | StTmApp

--: (string) -> StTmVar
function M.var(name) return { tag = "var", name = name } end
--: (string, Type, StTerm) -> StTmLam
function M.lam(param, paramType, body) return { tag = "lam", param = param, paramType = paramType, body = body } end
--: (StTerm, StTerm) -> StTmApp
function M.app(fn, arg) return { tag = "app", fn = fn, arg = arg } end

-- ── Typing context (hosted data) ───────────────────────────────────────────
-- Γ is an ordered list of bindings. The most recent binding wins on lookup (so
-- shadowing works). This is hosted vocabulary; the substrate sees only the
-- serialized list inside the claim args. The design removed Claim.scope
-- precisely to force Γ into args — this is where that lands.
--:: Binding = { name: string, type: Type }
--:: Context = { [integer]: Binding }

--: () -> Context
function M.empty_ctx() return {} end

-- Extend Γ with x:A, returning a NEW context (no mutation of the input).
--: (Context, string, Type) -> Context
function M.extend(ctx, name, ty)
	local out = {} --[[: Context ]]
	for i = 1, #ctx do out[i] = ctx[i] end
	out[#out + 1] = { name = name, type = ty }
	return out
end

-- ── Parsing (validate-not-cast; the trust obligation, per prop.lua finding) ──
-- The substrate hands back opaque ArgValue. The hosted checker must NOT cast it
-- to its grammar; it validates and reconstructs, returning nil on malformed
-- input. This is stronger than a cast and is the hosted-checker trust discipline.

local parse_type --[[: (unknown) -> Type | nil ]]
--: (unknown) -> Type | nil
parse_type = function(v)
	if type(v) ~= "table" then return nil end
	local tag = v.tag
	if tag == "base" then
		local name = v.name
		if type(name) ~= "string" then return nil end
		return { tag = "base", name = name }
	elseif tag == "arrow" then
		local from = parse_type(v.from)
		local to = parse_type(v.to)
		if not from or not to then return nil end
		return { tag = "arrow", from = from, to = to }
	end
	return nil
end

M.parse_type = parse_type

local parse_term --[[: (unknown) -> StTerm | nil ]]
--: (unknown) -> StTerm | nil
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
		local paramType = parse_type(v.paramType)
		if not paramType then return nil end
		local body = parse_term(v.body)
		if not body then return nil end
		return { tag = "lam", param = param, paramType = paramType, body = body }
	elseif tag == "app" then
		local fn = parse_term(v.fn)
		local arg = parse_term(v.arg)
		if not fn or not arg then return nil end
		return { tag = "app", fn = fn, arg = arg }
	end
	return nil
end

M.parse_term = parse_term

-- Parse a hosted Context (list of {name, type}). Returns nil on any malformed
-- entry. An absent/empty context parses to the empty list.
local parse_ctx --[[: (unknown) -> Context | nil ]]
--: (unknown) -> Context | nil
parse_ctx = function(v)
	if v == nil then return {} end
	if type(v) ~= "table" then return nil end
	local out = {} --[[: Context ]]
	for i = 1, #v do
		local b = v[i]
		if type(b) ~= "table" then return nil end
		local name = b.name
		local ty = parse_type(b.type)
		if type(name) ~= "string" or not ty then return nil end
		out[i] = { name = name, type = ty }
	end
	return out
end

M.parse_ctx = parse_ctx

-- ── Type operations (all EVIDENCE-LOCAL hosted vocabulary) ─────────────────

-- Structural type equality via the substrate serializer. STLC has no subtyping;
-- type identity is structural. (Subtyping would be a different, richer hosted
-- semantics — and the adversarial checks reject promoting `subtype` here.)
--: (Type, Type) -> boolean
local function type_eq(a, b)
	return A._serialize(a) == A._serialize(b)
end

M.type_eq = type_eq

-- Destructure an arrow type into (from, to), or (nil, nil) if not an arrow.
-- A small helper so call sites get cleanly-narrowed component types regardless
-- of how the union value reached them (field access vs local).
--: (Type) -> (Type | nil, Type | nil)
local function arrow_parts(ty)
	if ty.tag == "arrow" then return ty.from, ty.to end
	return nil, nil
end

-- Most-recent-wins lookup of `name` in Γ. Returns the bound Type or nil.
--: (Context, string) -> Type | nil
local function ctx_lookup(ctx, name)
	for i = #ctx, 1, -1 do
		if ctx[i].name == name then return ctx[i].type end
	end
	return nil
end

M.ctx_lookup = ctx_lookup

-- ── Claim builders ──────────────────────────────────────────────────────────
-- has_type(ctx, term_ref, ty): under typing context `ctx` (hosted data inline in
-- args), the term in artifact `term_ref` has type `ty` (hosted data inline). The
-- context and type are structurally part of claim identity (so has_type(Γ1,..)
-- and has_type(Γ2,..) are distinct claims), exactly as the design intends.

-- Serialize a Context to plain ArgValue (list of {name, type}). Types are
-- already plain tables, so this is identity-ish; we copy to a clean list to keep
-- claim args free of any non-data fields.
--: (Context) -> ArgValue
local function ctx_to_arg(ctx)
	local out = {} --[[: { [integer]: { name: string, type: Type } } ]]
	for i = 1, #ctx do out[i] = { name = ctx[i].name, type = ctx[i].type } end
	return out
end

M.ctx_to_arg = ctx_to_arg

--: ({ space: string, key: string }, Context, Id, Type) -> Claim
function M.has_type_claim(id, ctx, term_ref, ty)
	return A.claim({ id = id, semantics = M.ID, predicate = "has_type",
		args = {
			ctx = ctx_to_arg(ctx),
			term = { space = term_ref.space, key = term_ref.key },
			type = ty,
		} })
end

-- well_typed_type(ty): a structural claim that `ty` is a valid STLC type. Not
-- strictly needed for the rules (parse_type validates inline), but kept as an
-- explicit predicate so a well-formedness obligation can be made first-class if
-- a later rung wants it. Validated by `type_shape_check`.
--: ({ space: string, key: string }, Type) -> Claim
function M.well_typed_type_claim(id, ty)
	return A.claim({ id = id, semantics = M.ID, predicate = "well_typed_type",
		args = { type = ty } })
end

-- ── Helpers to read claim args / artifact terms ────────────────────────────

--: (unknown) -> Id | nil
local function arg_id(v)
	if type(v) ~= "table" then return nil end
	local space, key = v.space, v.key
	if type(space) ~= "string" or type(key) ~= "string" then return nil end
	return { space = space, key = key }
end

-- Read the StTerm content of an artifact referenced by Id, or nil.
--: (CheckContext, Id) -> StTerm | nil
local function term_of(ctx, ref)
	local art = ctx.get_artifact(ref)
	if not art then return nil end
	return parse_term(art.content_ref)
end

-- Read the (ctx, term, type) of an accepted has_type input claim. Returns the
-- parsed triple, or nil if the input is not a has_type claim or is malformed.
--: (CheckContext, Id) -> { ctx: Context, term: Id, type: Type } | nil
local function read_has_type(cc, ref)
	local c = cc.get_claim(ref)
	if not c or c.predicate ~= "has_type" then return nil end
	local a = c.args
	if type(a) ~= "table" then return nil end
	local pc = parse_ctx(a.ctx)
	local tref = arg_id(a.term)
	local ty = parse_type(a.type)
	if not pc or not tref or not ty then return nil end
	return { ctx = pc, term = tref, type = ty }
end

-- ── Checker ─────────────────────────────────────────────────────────────────
--
-- Typing rules as declarative-shaped dispatch. Each rule:
--   - re-derives the conclusion from the artifact term + premise claims;
--   - checks the asserted (ctx, term, type) in the claim against what the rule
--     produces — the checker validates its own inputs, never trusts their shape;
--   - records dependencies (artifact content + accepted premise claims).
--
-- DEEP EVIDENCE: abs consumes one has_type premise (Γ,x:A ⊢ body : B); app
-- consumes two (Γ ⊢ f : A→B and Γ ⊢ a : A). Those premises are themselves
-- accepted has_type claims with their own evidence, so derivations nest.

--: () -> unknown
local function trust_note() return A.unverified_checker_trust(M.ID, M.VERSION) end

--: HostedChecker
function M.checker(cc, claim, ev)
	local method = ev.method
	local args = claim.args
	if type(args) ~= "table" then
		return cc.REJECTED, "claim args are not a table", nil, nil
	end
	local predicate = claim.predicate

	if predicate == "well_typed_type" then
		if method ~= "type_shape_check" then
			return cc.UNKNOWN, "unknown well_typed_type method: " .. tostring(method), nil, nil
		end
		local ty = parse_type(args.type)
		if not ty then return cc.REJECTED, "type artifact is malformed STLC type", nil, nil end
		return cc.ACCEPTED, nil, {}, { trust_note() }

	elseif predicate == "has_type" then
		local ctx = parse_ctx(args.ctx)
		local tref = arg_id(args.term)
		local want_ty = parse_type(args.type)
		if not ctx then return cc.REJECTED, "has_type context is malformed", nil, nil end
		if not tref then return cc.REJECTED, "has_type missing term ref", nil, nil end
		if not want_ty then return cc.REJECTED, "has_type missing/malformed type", nil, nil end
		local term = term_of(cc, tref)
		if not term then return cc.REJECTED, "has_type term artifact is malformed STLC syntax", nil, nil end

		if method == "var_rule" then
			-- Var: x:A ∈ Γ  ⊢  Γ ⊢ x : A. No premise claims; depends only on the
			-- artifact content. The asserted type must match the binding in Γ.
			if term.tag ~= "var" then
				return cc.REJECTED, "var_rule applied to a non-variable term", nil, nil
			end
			local bound = ctx_lookup(ctx, term.name)
			if not bound then
				return cc.REJECTED, "var_rule: variable '" .. term.name .. "' not bound in context", nil, nil
			end
			if not type_eq(bound, want_ty) then
				return cc.REJECTED, "var_rule: asserted type does not match the binding in context", nil, nil
			end
			local deps = { A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = tref }) }
			return cc.ACCEPTED, nil, deps, { trust_note() }

		elseif method == "abs_rule" then
			-- Abs: Γ,x:A ⊢ body : B  ⊢  Γ ⊢ (λx:A. body) : A→B.
			-- One premise: the body typed under the EXTENDED context. The context
			-- extension Γ,x:A is hosted data we compute and compare against the
			-- premise claim's own context — never a substrate context slot.
			if term.tag ~= "lam" then
				return cc.REJECTED, "abs_rule applied to a non-abstraction term", nil, nil
			end
			if want_ty.tag ~= "arrow" then
				return cc.REJECTED, "abs_rule: asserted type is not an arrow", nil, nil
			end
			-- The arrow's domain must be the binder's declared type.
			if not type_eq(want_ty.from, term.paramType) then
				return cc.REJECTED, "abs_rule: arrow domain does not match the binder annotation", nil, nil
			end
			if #ev.inputs ~= 1 then
				return cc.REJECTED, "abs_rule requires exactly one has_type premise (the body)", nil, nil
			end
			local prem = ev.inputs[1]
			if not cc.is_accepted(prem) then
				return cc.UNKNOWN, nil, nil, nil
			end
			local pr = read_has_type(cc, prem)
			if not pr then return cc.REJECTED, "abs_rule premise is not a has_type claim", nil, nil end
			-- The premise must be exactly: (Γ,x:A) ⊢ body : B, where body is THIS
			-- term's body artifact, and B is the arrow codomain. We compare the
			-- premise's context to the extended context structurally.
			local extended = M.extend(ctx, term.param, term.paramType)
			if A._serialize(ctx_to_arg(extended)) ~= A._serialize(ctx_to_arg(pr.ctx)) then
				return cc.REJECTED, "abs_rule premise context is not Γ extended with the binder", nil, nil
			end
			-- The premise term must be the body of this lambda.
			local body_term = term_of(cc, pr.term)
			if not body_term or A._serialize(body_term) ~= A._serialize(term.body) then
				return cc.REJECTED, "abs_rule premise term is not the abstraction body", nil, nil
			end
			-- The premise type must be the arrow codomain.
			if not type_eq(pr.type, want_ty.to) then
				return cc.REJECTED, "abs_rule premise type does not match the arrow codomain", nil, nil
			end
			local deps = {
				A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = prem }),
				A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = tref }),
				A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = pr.term }),
			}
			return cc.ACCEPTED, nil, deps, { trust_note() }

		elseif method == "app_rule" then
			-- App: Γ ⊢ f : A→B  and  Γ ⊢ a : A  ⊢  Γ ⊢ (f a) : B.
			-- Two premises. Both must be under THIS claim's context Γ (no extension).
			if term.tag ~= "app" then
				return cc.REJECTED, "app_rule applied to a non-application term", nil, nil
			end
			if #ev.inputs ~= 2 then
				return cc.REJECTED, "app_rule requires exactly two has_type premises (fn, arg)", nil, nil
			end
			local fn_prem = ev.inputs[1]
			local arg_prem = ev.inputs[2]
			if not (cc.is_accepted(fn_prem) and cc.is_accepted(arg_prem)) then
				return cc.UNKNOWN, nil, nil, nil
			end
			local fpr = read_has_type(cc, fn_prem)
			local apr = read_has_type(cc, arg_prem)
			if not fpr or not apr then return cc.REJECTED, "app_rule premise is not a has_type claim", nil, nil end
			-- Both premises must share THIS claim's context.
			local ctx_ser = A._serialize(ctx_to_arg(ctx))
			if A._serialize(ctx_to_arg(fpr.ctx)) ~= ctx_ser or A._serialize(ctx_to_arg(apr.ctx)) ~= ctx_ser then
				return cc.REJECTED, "app_rule premises must share the conclusion's context", nil, nil
			end
			-- fn premise term must be this app's fn; arg premise term its arg.
			local fn_term = term_of(cc, fpr.term)
			local arg_term = term_of(cc, apr.term)
			if not fn_term or A._serialize(fn_term) ~= A._serialize(term.fn) then
				return cc.REJECTED, "app_rule fn premise term is not the application's function", nil, nil
			end
			if not arg_term or A._serialize(arg_term) ~= A._serialize(term.arg) then
				return cc.REJECTED, "app_rule arg premise term is not the application's argument", nil, nil
			end
			-- fn premise type must be an arrow A→B; arg premise type must be A;
			-- the asserted conclusion type must be B.
			local dom, cod = arrow_parts(fpr.type)
			if not dom or not cod then
				return cc.REJECTED, "app_rule function premise does not have an arrow type", nil, nil
			end
			if not type_eq(dom, apr.type) then
				return cc.REJECTED, "app_rule argument type does not match the function domain", nil, nil
			end
			if not type_eq(cod, want_ty) then
				return cc.REJECTED, "app_rule asserted type does not match the function codomain", nil, nil
			end
			local deps = {
				A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = fn_prem }),
				A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = arg_prem }),
				A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = tref }),
			}
			return cc.ACCEPTED, nil, deps, { trust_note() }

		elseif method == "trusted_type_axiom" then
			-- Accept Γ ⊢ term : T through a visible trust boundary (e.g. an
			-- external/FFI signature). The boundary is named in the result and
			-- recorded as a trusted-boundary dependency; the verdict does not check
			-- the typing, it admits it under explicit trust.
			local payload = ev.result
			local tb_id = type(payload) == "table" and arg_id(payload.trust) or nil
			if not tb_id then return cc.REJECTED, "trusted_type_axiom missing trust boundary", nil, nil end
			local tb = cc.state.trust_boundaries[A.idk(tb_id)]
			if not tb then return cc.REJECTED, "trusted_type_axiom references unknown trust boundary", nil, nil end
			local deps = {
				A.dependency({ from_claim = claim.id, kind = A.DEP_TRUSTED_BOUNDARY, target = tb.id }),
				A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = tref }),
			}
			return cc.ACCEPTED, nil, deps, { tb, trust_note() }
		end
		return cc.UNKNOWN, "unknown has_type method: " .. tostring(method), nil, nil
	end

	return cc.REJECTED, "unknown claim predicate: " .. tostring(claim.predicate), nil, nil
end

-- Register stlc.min in a registry.
--: (SemanticsRegistry) -> (boolean, string | nil)
function M.register(registry)
	return A.register(registry, {
		id = M.ID,
		version = M.VERSION,
		claim_predicates = { "has_type", "well_typed_type" },
		observation_predicates = { "term_shape", "type_shape" },
		evidence_methods = {
			"var_rule", "abs_rule", "app_rule", "type_shape_check", "trusted_type_axiom",
		},
		trusted_methods = { "trusted_type_axiom" },
		checker = M.checker,
	})
end

return M
