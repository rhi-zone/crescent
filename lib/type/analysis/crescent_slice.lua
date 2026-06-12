-- Hosted semantics: crescent.slice.v1
--
-- A tiny-but-real slice of Crescent/Lua static analysis, hosted on the agnostic
-- substrate (lib/type/analysis/init.lua), per
-- docs/agnostic-static-analysis-crescent-slice.md §2. It IMPORTS the substrate;
-- the substrate learns NOTHING new — no Type/Context/Subtype/Narrowing object
-- kind. Slice types (Ty, slice_ty.lua), typing contexts, subtype witnesses, and
-- instantiation witnesses all ride `ArgValue` claim args and evidence, exactly as
-- stlc.min's has_type did. The checker PARSES-NOT-CASTS its inputs and records
-- every accepted claim with `unverified_checker_trust` (the hosted-checker trust
-- obligation).
--
-- This file is Pass 2 of the mechanization (§8): the synthesis/checking evidence
-- methods, the registry entry, `trusted_signature`, `instantiate_witness`, and the
-- `type_shape_check` well-formedness (incl. μ contractiveness, §9.3 finding 1).
-- The flow-narrowing layer (`narrow_guard`, narrows) is Pass 3; the corpus +
-- for-in/numeric-for handling is Pass 4. Nothing here precludes them.
--
-- Errors are (rejected result class) / nil returns; the checker never throws for
-- data errors.

local A = require("lib.type.analysis")
local G = require("lib.type.analysis.slice_ty")
local TA = require("lib.type.analysis.slice_ty_arg")
local SUB = require("lib.type.analysis.slice_subtype")

local M = {}

M.ID = "crescent.slice.v1"
M.VERSION = "0"

-- ── Syntax-node grammar (hosted vocabulary, opaque to the substrate) ─────────
--
-- A Node is a parsed Lua syntax form in v1's subset (§5). It is plain ArgValue
-- data stored in an `artifact` of kind "syntax_tree" and referenced by Id. The
-- substrate never interprets it. The slice's parser-frontend adapter
-- (crescent_slice_parse.lua) produces these; the evidence methods parse them back.
--
--   { t="lit", lit="int"|"num"|"str"|"bool"|"nil", v=<value> }
--   { t="var", name=string }
--   { t="call", fn=Node, args={ Node.. } }
--   { t="table", entries={ { key?: string, ikey?: integer, value: Node }.. }, array={ Node.. } }
--   { t="index", obj=Node, field?: string, key?: Node }     -- t.field or t[key]
--   { t="function", params={ { name, type: PTy }.. }, vararg?: PTy, ret?: PTy, returns={ {Node..}.. } }
--   { t="andor", op="and"|"or"|"not", left=Node, right?: Node }
--   { t="cast", expr=Node, type=PTy, force: boolean }       -- e --[[: T]] / e --[[:! T]]
--
-- (Statements — local decls, if/elseif, assignments — are handled by the adapter,
--  which lowers them into the claim graph; the synthesizable EXPRESSION forms are
--  the node grammar above.)

-- ── Claim builders (context-in-args, the STLC/lambda-rung discipline) ────────
--
-- Γ (Context) is the STLC binding list, extended to slice types: an ordered
-- list of { name: string, type: PTy } where the type is the PORTABLE encoding
-- (slice_ty_arg.lua). Most-recent-wins, structurally part of identity. No
-- Claim.scope; it rides args, verbatim STLC.
--:: SliceBinding = { name: string, type: PTy }
--:: SliceCtx = { [integer]: SliceBinding }

--: () -> SliceCtx
function M.empty_ctx() return {} end

-- Extend Γ with name:ty (ty an interned Ty), returning a NEW context.
--: (SliceCtx, string, Ty) -> SliceCtx
function M.extend(ctx, name, ty)
	local out = {} --[[: SliceCtx ]]
	for i = 1, #ctx do out[i] = ctx[i] end
	out[#out + 1] = { name = name, type = TA.encode(ty) }
	return out
end

-- ── Parse-not-cast helpers (the hosted-checker trust discipline) ─────────────

--: (unknown) -> Id | nil
local function arg_id(v)
	if type(v) ~= "table" then return nil end
	local space, key = v.space, v.key
	if type(space) ~= "string" or type(key) ~= "string" then return nil end
	return { space = space, key = key }
end

-- Parse a hosted SliceCtx (list of {name, PTy}) into a binding list with each
-- type DECODED to an interned Ty. Returns nil on any malformed entry.
--: (unknown) -> { [integer]: { name: string, type: Ty } } | nil
local function parse_ctx(v)
	if v == nil then return {} end
	if type(v) ~= "table" then return nil end
	local out = {} --[[: { [integer]: { name: string, type: Ty } } ]]
	for i = 1, #v do
		local b = v[i]
		if type(b) ~= "table" then return nil end
		local name = b.name
		if type(name) ~= "string" then return nil end
		local ty = TA.decode(b.type)
		if not ty then return nil end
		out[i] = { name = name, type = ty }
	end
	return out
end

M.parse_ctx = parse_ctx

-- Most-recent-wins lookup of `name` in a parsed Γ. Returns the bound Ty or nil.
--: ({ [integer]: { name: string, type: Ty } }, string) -> Ty | nil
local function ctx_lookup(ctx, name)
	for i = #ctx, 1, -1 do
		if ctx[i].name == name then return ctx[i].type end
	end
	return nil
end

M.ctx_lookup = ctx_lookup

-- Read the Node content of an artifact referenced by Id, or nil. The node is
-- arbitrary ArgValue; per-rule parsing validates the shape it needs.
--: (CheckContext, Id) -> unknown
local function node_of(cc, ref)
	local art = cc.get_artifact(ref)
	if not art then return nil end
	return art.content_ref
end

-- Read the (ctx, node_ref, type) of an accepted has_type / checks_against input
-- claim. Returns the parsed triple (type DECODED to Ty), or nil if malformed or
-- the wrong predicate.
--: (CheckContext, Id, string) -> { ctx: { [integer]: { name: string, type: Ty } }, node: Id, type: Ty } | nil
local function read_typing(cc, ref, predicate)
	local c = cc.get_claim(ref)
	if not c or c.predicate ~= predicate then return nil end
	local a = c.args
	if type(a) ~= "table" then return nil end
	local pc = parse_ctx(a.ctx)
	local nref = arg_id(a.node)
	local ty = TA.decode(a.type)
	if not pc or not nref or not ty then return nil end
	return { ctx = pc, node = nref, type = ty }
end

M.read_typing = read_typing

-- Serialize a parsed Γ back to ArgValue (for structural context comparison
-- between a conclusion and its premises). Uses re-encoded portable types so the
-- comparison is over canonical (interner-faithful) forms.
--: ({ [integer]: { name: string, type: Ty } }) -> ArgValue
local function ctx_to_arg(ctx)
	local out = {} --[[: { [integer]: { name: string, type: PTy } } ]]
	for i = 1, #ctx do out[i] = { name = ctx[i].name, type = TA.encode(ctx[i].type) } end
	return out
end

M.ctx_to_arg = ctx_to_arg

-- A raw context (list of {name, type=PTy}) directly to ArgValue, for builders.
--: (SliceCtx) -> ArgValue
local function raw_ctx_to_arg(ctx)
	local out = {} --[[: { [integer]: { name: string, type: PTy } } ]]
	for i = 1, #ctx do out[i] = { name = ctx[i].name, type = ctx[i].type } end
	return out
end

-- Build a has_type(Γ, node_ref, T) claim. T is an interned Ty; it is encoded to
-- the portable form for the args. Γ is a raw SliceCtx (portable types already).
--: (Id, SliceCtx, Id, Ty) -> Claim
function M.has_type_claim(id, ctx, node_ref, ty)
	return A.claim({ id = id, semantics = M.ID, predicate = "has_type",
		args = { ctx = raw_ctx_to_arg(ctx), node = { space = node_ref.space, key = node_ref.key }, type = TA.encode(ty) } })
end

-- Build a checks_against(Γ, node_ref, T) claim.
--: (Id, SliceCtx, Id, Ty) -> Claim
function M.checks_against_claim(id, ctx, node_ref, ty)
	return A.claim({ id = id, semantics = M.ID, predicate = "checks_against",
		args = { ctx = raw_ctx_to_arg(ctx), node = { space = node_ref.space, key = node_ref.key }, type = TA.encode(ty) } })
end

-- Build a subtype(A, B) claim — NO context (subtyping is context-free in v1, §2.2).
--: (Id, Ty, Ty) -> Claim
function M.subtype_claim(id, a, b)
	return A.claim({ id = id, semantics = M.ID, predicate = "subtype",
		args = { a = TA.encode(a), b = TA.encode(b) } })
end

-- Build a well_typed_type(T) claim.
--: (Id, Ty) -> Claim
function M.well_typed_type_claim(id, ty)
	return A.claim({ id = id, semantics = M.ID, predicate = "well_typed_type",
		args = { type = TA.encode(ty) } })
end

-- ── Structural Ty identity via the interner ──────────────────────────────────
-- Two interned Ty are equal iff their tids match (slice_ty guarantees structural
-- identity ⇒ tid identity). This is the slice's `type_eq`.
--: (Ty, Ty) -> boolean
local function ty_eq(a, b) return a.tid == b.tid end

M.ty_eq = ty_eq

-- ── Trust note (hosted-checker trust obligation) ─────────────────────────────
--: () -> unknown
local function trust_note() return A.unverified_checker_trust(M.ID, M.VERSION) end

-- ── Literal-node synthesis ───────────────────────────────────────────────────
-- A literal node ⇒ its singleton type (§2.3 synth_lit).
--: (unknown) -> Ty | nil
local function synth_literal(node)
	if type(node) ~= "table" then return nil end
	if node.t ~= "lit" then return nil end
	local lit = node.lit
	local v = node.v
	if lit == "nil" then return G.nil_() end
	if lit == "bool" then
		if type(v) ~= "boolean" then return nil end
		return G.lit_bool(v)
	end
	if lit == "int" then
		if type(v) ~= "number" then return nil end
		return G.lit_int(v)
	end
	if lit == "num" then
		if type(v) ~= "number" then return nil end
		return G.lit_num(v)
	end
	if lit == "str" then
		if type(v) ~= "string" then return nil end
		return G.lit_str(v)
	end
	return nil
end

-- ── synth_index: field / index access (§2.3) ─────────────────────────────────
-- Given the object's type `obj_ty` and the access, returns the synthesized field
-- type or nil (no such field / inadmissible). `field` is the static key (t.field
-- or t["field"]); `key_ty` is the dynamic key type for t[e].
--
-- Distributes over unions (present in ALL members) and intersections (ANY member).
local index_result --[[: (Ty, string | nil, Ty | nil) -> Ty | nil ]]

--: (Ty, string | nil, Ty | nil) -> Ty | nil
index_result = function(obj_ty, field, key_ty)
	local k = obj_ty.kind

	if k == "mu" then
		return index_result(G.unfold(obj_ty), field, key_ty)
	end

	if k == "union" then
		-- accessible iff present in ALL members; result is the union of results.
		local ms = obj_ty.members or {}
		local results = {} --[[: Ty[] ]]
		for i = 1, #ms do
			local r = index_result(ms[i], field, key_ty)
			if not r then return nil end
			results[#results + 1] = r
		end
		if #results == 0 then return nil end
		return G.union(results)
	end

	if k == "inter" then
		-- present in ANY member; result is that member's result (first hit).
		local ms = obj_ty.members or {}
		for i = 1, #ms do
			local r = index_result(ms[i], field, key_ty)
			if r then return r end
		end
		return nil
	end

	if k == "rec" or k == "rec_with_indexer" then
		local fields = obj_ty.fields or {}
		if field ~= nil then
			for i = 1, #fields do
				if fields[i].key == field then
					local fty = fields[i].ty
					if fields[i].optional then return G.union({ fty, G.nil_() }) end
					return fty
				end
			end
			-- field not listed
			if k == "rec_with_indexer" then
				-- key admitted by the index signature?
				local lit = G.lit_str(field)
				if obj_ty.key and SUB.is_subtype(lit, obj_ty.key) then
					return obj_ty.val
				end
			end
			if obj_ty.rows == "open" then return G.unknown() end -- open-row: unlisted ⇒ unknown
			return nil -- closed rec without the field ⇒ reject
		end
		-- dynamic key t[e]
		if key_ty ~= nil and k == "rec_with_indexer" and obj_ty.key then
			if SUB.is_subtype(key_ty, obj_ty.key) then return obj_ty.val end
		end
		if obj_ty.rows == "open" then return G.unknown() end
		return nil
	end

	if k == "indexer" then
		if key_ty ~= nil and obj_ty.key and SUB.is_subtype(key_ty, obj_ty.key) then
			return obj_ty.val
		end
		if field ~= nil and obj_ty.key then
			local lit = G.lit_str(field)
			if SUB.is_subtype(lit, obj_ty.key) then return obj_ty.val end
		end
		return nil
	end

	return nil
end

M.index_result = index_result

-- ── synth_table: table constructor (§2.3) ────────────────────────────────────
-- Synthesizes the PRECISE type from per-entry types. Named entries produce a
-- `rec`. Positional/array entries add an `indexer(integer, V)` where V is the
-- precise union of element types — so the synthesized type is `<:` a declared
-- `{ [integer]: Insn, ... }` exactly when every element `<:` Insn (widening at
-- the CHECKING boundary, not here). `named` is the named fields; `array` is the
-- ordered element types.
--: ({ [integer]: { key: string, ty: Ty } }, Ty[]) -> Ty
local function synth_table_type(named, array)
	local fields = {} --[[: Field[] ]]
	for i = 1, #named do
		fields[#fields + 1] = { key = named[i].key, ty = named[i].ty, optional = false, readonly = false }
	end
	if #array == 0 then
		return G.rec(fields, "closed")
	end
	local elems = {} --[[: Ty[] ]]
	for i = 1, #array do elems[i] = array[i] end
	local elem = G.union(elems)
	if #fields == 0 then
		return G.indexer(G.integer(), elem)
	end
	return G.rec_with_indexer(fields, "closed", { key = G.integer(), val = elem })
end

M.synth_table_type = synth_table_type

-- ── Dependency helpers ───────────────────────────────────────────────────────

--: (Id, Id) -> Dependency
local function dep_artifact(from, target)
	return A.dependency({ from_claim = from, kind = A.DEP_ARTIFACT_CONTENT, target = target })
end
--: (Id, Id) -> Dependency
local function dep_claim(from, target)
	return A.dependency({ from_claim = from, kind = A.DEP_ACCEPTED_CLAIM, target = target })
end
--: (Id, Id) -> Dependency
local function dep_trust(from, target)
	return A.dependency({ from_claim = from, kind = A.DEP_TRUSTED_BOUNDARY, target = target })
end

-- Read a subtype claim's (A, B) decoded, or nil.
--: (CheckContext, Id) -> { a: Ty, b: Ty } | nil
local function read_subtype(cc, ref)
	local c = cc.get_claim(ref)
	if not c or c.predicate ~= "subtype" then return nil end
	local args = c.args
	if type(args) ~= "table" then return nil end
	local a = TA.decode(args.a)
	local b = TA.decode(args.b)
	if not a or not b then return nil end
	return { a = a, b = b }
end

-- ── The hosted checker ───────────────────────────────────────────────────────
--
-- Each evidence method re-derives its conclusion from the artifact node + premise
-- claims, checks the asserted (Γ, node, T) against what the rule produces, and
-- records dependencies. Premise-not-yet-accepted ⇒ UNKNOWN (retry), never
-- REJECTED — the order-independence discipline. The checker validates its own
-- inputs (parse-not-cast) and trusts no arg shape.

--: HostedChecker
function M.checker(cc, claim, ev)
	local method = ev.method
	local predicate = claim.predicate
	local args = claim.args
	if type(args) ~= "table" then
		return cc.REJECTED, "claim args are not a table", nil, nil
	end

	-- ── well_typed_type ──────────────────────────────────────────────────────
	if predicate == "well_typed_type" then
		if method ~= "type_shape_check" then
			return cc.UNKNOWN, "unknown well_typed_type method: " .. tostring(method), nil, nil
		end
		local ty = TA.decode(args.type)
		if not ty then return cc.REJECTED, "type artifact is malformed slice Ty", nil, nil end
		if not TA.well_formed(ty) then
			return cc.REJECTED, "type is not well-formed (non-contractive μ or invalid shape)", nil, nil
		end
		return cc.ACCEPTED, nil, {}, { trust_note() }
	end

	-- ── subtype ──────────────────────────────────────────────────────────────
	if predicate == "subtype" then
		if method ~= "subtype_witness" then
			return cc.UNKNOWN, "unknown subtype method: " .. tostring(method), nil, nil
		end
		local pair = read_subtype(cc, claim.id)
		if not pair then return cc.REJECTED, "subtype claim args are malformed", nil, nil end
		local ok, counter = SUB.subtype(pair.a, pair.b)
		if not ok then
			-- surface the counterexample in the diagnostic (the rejection-with-
			-- counterevidence path, §6.4 — the substrate has no separate slot, so the
			-- counterexample's constructor pair is named in the diagnostic string).
			local detail = counter and (": " .. tostring(counter.kind)) or ""
			return cc.REJECTED, "not a subtype" .. detail, nil, nil
		end
		return cc.ACCEPTED, nil, {}, { trust_note() }
	end

	-- ── has_type / checks_against ────────────────────────────────────────────
	if predicate ~= "has_type" and predicate ~= "checks_against" then
		return cc.REJECTED, "unknown claim predicate: " .. tostring(claim.predicate), nil, nil
	end

	local ctx = parse_ctx(args.ctx)
	local nref = arg_id(args.node)
	local want_ty = TA.decode(args.type)
	if not ctx then return cc.REJECTED, predicate .. " context is malformed", nil, nil end
	if not nref then return cc.REJECTED, predicate .. " missing node ref", nil, nil end
	if not want_ty then return cc.REJECTED, predicate .. " missing/malformed type", nil, nil end
	local node = node_of(cc, nref)
	if type(node) ~= "table" then
		return cc.REJECTED, predicate .. " node artifact is malformed slice syntax", nil, nil
	end

	-- helper: accept with the node-artifact dep + premise deps + trust.
	--: (Dependency[], unknown[]) -> (string, string | nil, Dependency[], unknown[])
	local function accept(deps, trust)
		deps[#deps + 1] = dep_artifact(claim.id, nref)
		return cc.ACCEPTED, nil, deps, trust
	end

	-- ── synth_lit ──
	if method == "synth_lit" then
		local s = synth_literal(node)
		if not s then return cc.REJECTED, "synth_lit applied to a non-literal node", nil, nil end
		if not ty_eq(s, want_ty) then
			return cc.REJECTED, "synth_lit: asserted type does not match the literal's singleton", nil, nil
		end
		return accept({}, { trust_note() })

	-- ── synth_var ──
	elseif method == "synth_var" then
		if node.t ~= "var" then return cc.REJECTED, "synth_var applied to a non-variable node", nil, nil end
		local name = node.name
		if type(name) ~= "string" then return cc.REJECTED, "synth_var: malformed variable node", nil, nil end
		local bound = ctx_lookup(ctx, name)
		if not bound then return cc.REJECTED, "synth_var: '" .. name .. "' not bound in context", nil, nil end
		if not ty_eq(bound, want_ty) then
			return cc.REJECTED, "synth_var: asserted type does not match the binding in context", nil, nil
		end
		return accept({}, { trust_note() })

	-- ── synth_index ──
	elseif method == "synth_index" then
		if node.t ~= "index" then return cc.REJECTED, "synth_index applied to a non-index node", nil, nil end
		-- premise: has_type(Γ, obj_node, OBJ_T).
		if #ev.inputs ~= 1 then return cc.REJECTED, "synth_index requires one has_type premise (the object)", nil, nil end
		local prem = ev.inputs[1]
		if not cc.is_accepted(prem) then return cc.UNKNOWN, nil, nil, nil end
		local pr = read_typing(cc, prem, "has_type")
		if not pr then return cc.REJECTED, "synth_index premise is not a has_type claim", nil, nil end
		-- premise context must equal this claim's context.
		if A._serialize(ctx_to_arg(ctx)) ~= A._serialize(ctx_to_arg(pr.ctx)) then
			return cc.REJECTED, "synth_index premise context must match the conclusion's", nil, nil
		end
		-- premise node must be this index's object.
		local obj_ref = arg_id(node.obj)
		if not obj_ref or obj_ref.space ~= pr.node.space or obj_ref.key ~= pr.node.key then
			return cc.REJECTED, "synth_index premise node is not the access object", nil, nil
		end
		local nfield = node.field
		local field --[[: string | nil ]]
		if type(nfield) == "string" then field = nfield end
		-- (dynamic-key t[e] resolution: v1 handles the static-field case; a dynamic
		--  key needs its own has_type premise — out of this rule's 1-premise form.)
		local res = index_result(pr.type, field, nil)
		if not res then
			-- no-such-field counterevidence (§6.4) surfaced in the diagnostic.
			return cc.REJECTED, "synth_index: no such field '" .. tostring(field) .. "' (no_such_field)", nil, nil
		end
		if not ty_eq(res, want_ty) then
			return cc.REJECTED, "synth_index: asserted type does not match the field type", nil, nil
		end
		return accept({ dep_claim(claim.id, prem) }, { trust_note() })

	-- ── synth_table ──
	elseif method == "synth_table" then
		if node.t ~= "table" then return cc.REJECTED, "synth_table applied to a non-table node", nil, nil end
		-- premises: one has_type per value expression (named entries then array).
		local entries = node.entries
		local array = node.array
		if entries ~= nil and type(entries) ~= "table" then return cc.REJECTED, "synth_table malformed entries", nil, nil end
		if array ~= nil and type(array) ~= "table" then return cc.REJECTED, "synth_table malformed array", nil, nil end
		local named = {} --[[: { [integer]: { key: string, ty: Ty } } ]]
		local arr = {} --[[: Ty[] ]]
		local deps = {} --[[: Dependency[] ]]
		local ip = 1 --: integer
		-- each premise corresponds positionally to a value expression.
		if type(entries) == "table" then
			for i = 1, #entries do
				local e = entries[i]
				if type(e) ~= "table" then return cc.REJECTED, "synth_table entry malformed", nil, nil end
				local ekey = e.key
				if type(ekey) ~= "string" then return cc.REJECTED, "synth_table entry malformed", nil, nil end
				local prem = ev.inputs[ip]; ip = ip + 1
				if not prem then return cc.REJECTED, "synth_table missing a value premise", nil, nil end
				if not cc.is_accepted(prem) then return cc.UNKNOWN, nil, nil, nil end
				local pr = read_typing(cc, prem, "has_type")
				if not pr then return cc.REJECTED, "synth_table premise is not a has_type claim", nil, nil end
				named[#named + 1] = { key = ekey, ty = pr.type }
				deps[#deps + 1] = dep_claim(claim.id, prem)
			end
		end
		if type(array) == "table" then
			for i = 1, #array do
				local prem = ev.inputs[ip]; ip = ip + 1
				if not prem then return cc.REJECTED, "synth_table missing an array premise", nil, nil end
				if not cc.is_accepted(prem) then return cc.UNKNOWN, nil, nil, nil end
				local pr = read_typing(cc, prem, "has_type")
				if not pr then return cc.REJECTED, "synth_table premise is not a has_type claim", nil, nil end
				arr[#arr + 1] = pr.type
			end
		end
		local synth = synth_table_type(named, arr)
		if not ty_eq(synth, want_ty) then
			return cc.REJECTED, "synth_table: asserted type does not match the synthesized record", nil, nil
		end
		return accept(deps, { trust_note() })

	-- ── synth_and_or_not ──
	elseif method == "synth_and_or_not" then
		if node.t ~= "andor" then return cc.REJECTED, "synth_and_or_not applied to a non-connective node", nil, nil end
		local op = node.op
		if op == "not" then
			-- `not a` ⇒ boolean (no premise needed beyond shape).
			if not ty_eq(G.boolean(), want_ty) then
				return cc.REJECTED, "synth_and_or_not: `not` synthesizes boolean", nil, nil
			end
			return accept({}, { trust_note() })
		end
		if op ~= "and" and op ~= "or" then return cc.REJECTED, "synth_and_or_not: unknown connective", nil, nil end
		-- premises: has_type for left and right operands.
		if #ev.inputs ~= 2 then return cc.REJECTED, "synth_and_or_not requires two has_type premises", nil, nil end
		local lp, rp = ev.inputs[1], ev.inputs[2]
		if not (cc.is_accepted(lp) and cc.is_accepted(rp)) then return cc.UNKNOWN, nil, nil, nil end
		local lpr = read_typing(cc, lp, "has_type")
		local rpr = read_typing(cc, rp, "has_type")
		if not lpr or not rpr then return cc.REJECTED, "synth_and_or_not premise is not a has_type claim", nil, nil end
		-- v1 positive decomposition (§4.1): if the left operand is <: boolean, the
		-- result of `and`/`or` is boolean (both branches boolean — the boolean-
		-- narrowing fixture). Otherwise `(left minus falsy) | right`; with no
		-- complement, v1 approximates `left | right`.
		local result --[[: Ty ]]
		if SUB.is_subtype(lpr.type, G.boolean()) and SUB.is_subtype(rpr.type, G.boolean()) then
			result = G.boolean()
		else
			result = G.union({ lpr.type, rpr.type })
		end
		if not ty_eq(result, want_ty) then
			return cc.REJECTED, "synth_and_or_not: asserted type does not match the connective result", nil, nil
		end
		return accept({ dep_claim(claim.id, lp), dep_claim(claim.id, rp) }, { trust_note() })

	-- ── synth_call ──
	elseif method == "synth_call" then
		if node.t ~= "call" then return cc.REJECTED, "synth_call applied to a non-call node", nil, nil end
		-- premises: has_type(Γ, fn_node, fn(P,R)) then one checks_against per arg.
		if #ev.inputs < 1 then return cc.REJECTED, "synth_call requires at least the function premise", nil, nil end
		local fn_prem = ev.inputs[1]
		if not cc.is_accepted(fn_prem) then return cc.UNKNOWN, nil, nil, nil end
		local fpr = read_typing(cc, fn_prem, "has_type")
		if not fpr then return cc.REJECTED, "synth_call function premise is not a has_type claim", nil, nil end
		local ftype = fpr.type
		if ftype.kind ~= "fn" then return cc.REJECTED, "synth_call: callee does not have a function type", nil, nil end
		local params = ftype.params or ({ fixed = {} } --[[: Params ]])
		local ret = ftype.ret or ({ fixed = {} } --[[: Ret ]])
		-- argument premises: checks_against(Γ, arg_i, P.fixed[i] or vararg).
		local call_args = node.args
		if call_args ~= nil and type(call_args) ~= "table" then return cc.REJECTED, "synth_call malformed args", nil, nil end
		local nargs = type(call_args) == "table" and #call_args or 0
		local deps = { dep_claim(claim.id, fn_prem) } --[[: Dependency[] ]]
		for i = 1, nargs do
			local prem = ev.inputs[i + 1]
			if not prem then return cc.REJECTED, "synth_call missing an argument premise", nil, nil end
			if not cc.is_accepted(prem) then return cc.UNKNOWN, nil, nil, nil end
			local apr = read_typing(cc, prem, "checks_against")
			if not apr then return cc.REJECTED, "synth_call argument premise is not a checks_against claim", nil, nil end
			-- the expected param type for slot i.
			local want_param --[[: Ty | nil ]]
			if i <= #params.fixed then want_param = params.fixed[i] else want_param = params.vararg end
			if not want_param then return cc.REJECTED, "synth_call: too many arguments for the callee", nil, nil end
			if not ty_eq(apr.type, want_param) then
				return cc.REJECTED, "synth_call: argument " .. i .. " not checked against the parameter type", nil, nil
			end
			deps[#deps + 1] = dep_claim(claim.id, prem)
		end
		-- synthesized call type in single-value context: R.fixed[1] (or nil if empty).
		local result --[[: Ty ]]
		if #ret.fixed >= 1 then result = ret.fixed[1] else result = G.nil_() end
		if not ty_eq(result, want_ty) then
			return cc.REJECTED, "synth_call: asserted type does not match the callee's return", nil, nil
		end
		return accept(deps, { trust_note() })

	-- ── synth_function ──
	elseif method == "synth_function" then
		if node.t ~= "function" then return cc.REJECTED, "synth_function applied to a non-function node", nil, nil end
		-- The asserted type must be a fn(P, R). The body's return statements are
		-- checked under Γ extended with the params via SEPARATE premises (each a
		-- checks_against against R). v1 requires the function annotated (§7.1).
		if want_ty.kind ~= "fn" then return cc.REJECTED, "synth_function: asserted type is not a function", nil, nil end
		-- premises: one checks_against(Γ', ret_expr_i, R-slot) per return expr.
		-- The producer supplies them; we verify each is under the extended Γ and
		-- checks against the declared return tuple's first slot (single-return v1).
		local ret = want_ty.ret or ({ fixed = {} } --[[: Ret ]])
		local rty --[[: Ty ]]
		if #ret.fixed >= 1 then rty = ret.fixed[1] else rty = G.nil_() end
		-- build the extended context: Γ, p1:T1, ..., pn:Tn.
		local params_node = node.params
		if params_node ~= nil and type(params_node) ~= "table" then return cc.REJECTED, "synth_function malformed params", nil, nil end
		local ext = {} --[[: { [integer]: { name: string, type: Ty } } ]]
		for i = 1, #ctx do ext[i] = ctx[i] end
		local pfixed = (want_ty.params or ({ fixed = {} } --[[: Params ]])).fixed
		if type(params_node) == "table" then
			for i = 1, #params_node do
				local p = params_node[i]
				if type(p) ~= "table" then return cc.REJECTED, "synth_function param malformed", nil, nil end
				local pname = p.name
				if type(pname) ~= "string" then return cc.REJECTED, "synth_function param malformed", nil, nil end
				local pty = pfixed[i]
				if not pty then return cc.REJECTED, "synth_function: param count exceeds the declared type", nil, nil end
				ext[#ext + 1] = { name = pname, type = pty }
			end
		end
		local ext_ser = A._serialize(ctx_to_arg(ext))
		local deps = {} --[[: Dependency[] ]]
		for i = 1, #ev.inputs do
			local prem = ev.inputs[i]
			if not cc.is_accepted(prem) then return cc.UNKNOWN, nil, nil, nil end
			local rpr = read_typing(cc, prem, "checks_against")
			if not rpr then return cc.REJECTED, "synth_function premise is not a checks_against claim", nil, nil end
			if A._serialize(ctx_to_arg(rpr.ctx)) ~= ext_ser then
				return cc.REJECTED, "synth_function return premise is not under Γ extended with the params", nil, nil
			end
			if not ty_eq(rpr.type, rty) then
				return cc.REJECTED, "synth_function return premise is not checked against the declared return", nil, nil
			end
			deps[#deps + 1] = dep_claim(claim.id, prem)
		end
		return accept(deps, { trust_note() })

	-- ── check_against (the mode switch: synth ⇒ S, then subtype(S, T)) ──
	elseif method == "check_against" then
		if predicate ~= "checks_against" then
			return cc.REJECTED, "check_against produces a checks_against claim", nil, nil
		end
		-- premises: has_type(Γ, node, S) and subtype(S, T).
		if #ev.inputs ~= 2 then return cc.REJECTED, "check_against requires has_type + subtype premises", nil, nil end
		local sp, subp = ev.inputs[1], ev.inputs[2]
		if not (cc.is_accepted(sp) and cc.is_accepted(subp)) then return cc.UNKNOWN, nil, nil, nil end
		local spr = read_typing(cc, sp, "has_type")
		if not spr then return cc.REJECTED, "check_against synth premise is not a has_type claim", nil, nil end
		-- the synth premise must be the SAME node under the SAME context.
		if spr.node.space ~= nref.space or spr.node.key ~= nref.key then
			return cc.REJECTED, "check_against synth premise is not this node", nil, nil
		end
		if A._serialize(ctx_to_arg(ctx)) ~= A._serialize(ctx_to_arg(spr.ctx)) then
			return cc.REJECTED, "check_against synth premise context must match", nil, nil
		end
		local sub = read_subtype(cc, subp)
		if not sub then return cc.REJECTED, "check_against subtype premise is malformed", nil, nil end
		-- the subtype premise must be subtype(S, T) for this S and the wanted T.
		if not ty_eq(sub.a, spr.type) or not ty_eq(sub.b, want_ty) then
			return cc.REJECTED, "check_against subtype premise is not subtype(synth, expected)", nil, nil
		end
		return accept({ dep_claim(claim.id, sp), dep_claim(claim.id, subp) }, { trust_note() })

	-- ── check_cast (e --[[: T]] — a checking boundary, never inference) ──
	elseif method == "check_cast" then
		if node.t ~= "cast" then return cc.REJECTED, "check_cast applied to a non-cast node", nil, nil end
		if node.force == true then return cc.REJECTED, "force cast is a trusted_signature, not check_cast", nil, nil end
		-- the cast yields T (the asserted type). premises: has_type(Γ, inner, S),
		-- subtype(S, T). Mirror check_against, over the inner expression.
		if #ev.inputs ~= 2 then return cc.REJECTED, "check_cast requires has_type + subtype premises", nil, nil end
		local sp, subp = ev.inputs[1], ev.inputs[2]
		if not (cc.is_accepted(sp) and cc.is_accepted(subp)) then return cc.UNKNOWN, nil, nil, nil end
		local spr = read_typing(cc, sp, "has_type")
		if not spr then return cc.REJECTED, "check_cast synth premise is not a has_type claim", nil, nil end
		local inner_ref = arg_id(node.expr)
		if not inner_ref or spr.node.space ~= inner_ref.space or spr.node.key ~= inner_ref.key then
			return cc.REJECTED, "check_cast synth premise is not the cast's inner expression", nil, nil
		end
		local cast_ty = TA.decode(node.type)
		if not cast_ty then return cc.REJECTED, "check_cast: malformed cast type", nil, nil end
		if not ty_eq(cast_ty, want_ty) then
			return cc.REJECTED, "check_cast: asserted type must equal the cast type", nil, nil
		end
		local sub = read_subtype(cc, subp)
		if not sub then return cc.REJECTED, "check_cast subtype premise is malformed", nil, nil end
		if not ty_eq(sub.a, spr.type) or not ty_eq(sub.b, cast_ty) then
			return cc.REJECTED, "check_cast subtype premise is not subtype(inner, castType)", nil, nil
		end
		return accept({ dep_claim(claim.id, sp), dep_claim(claim.id, subp) }, { trust_note() })

	-- ── instantiate_witness (local generic instantiation at a call site, §2.4) ──
	elseif method == "instantiate_witness" then
		if predicate ~= "has_type" then return cc.REJECTED, "instantiate_witness produces a has_type claim", nil, nil end
		if node.t ~= "call" then return cc.REJECTED, "instantiate_witness applies at a call node", nil, nil end
		-- The witness payload (untrusted, produced by the solver):
		--   payload.generic : PTy   the GENERIC callee type, type parameters as
		--                            FREE tyvar nodes (not interned — free tyvars
		--                            are not a grammar construct, so they ride the
		--                            portable layer only).
		--   payload.subst   : { [name]: PTy }   the proposed substitution σ.
		-- The checker APPLIES σ to G and validates the application post-hoc; it
		-- NEVER infers σ. This is the fixpoint-rung witness pattern.
		local payload = ev.result
		if type(payload) ~= "table" then return cc.REJECTED, "instantiate_witness missing payload", nil, nil end
		local generic = payload.generic
		local praw = payload.subst
		if type(generic) ~= "table" or type(praw) ~= "table" then
			return cc.REJECTED, "instantiate_witness missing generic-type or σ payload", nil, nil
		end
		local subst = {} --[[: { [string]: Ty } ]]
		for name, pty in pairs(praw) do
			local d = TA.decode(pty)
			if not d then return cc.REJECTED, "instantiate_witness σ has a malformed type", nil, nil end
			if type(name) == "string" then subst[name] = d end
		end
		local applied = TA.apply_subst_pty(generic, subst)
		if not applied then return cc.REJECTED, "instantiate_witness: σ application/decode failed", nil, nil end
		if applied.kind ~= "fn" then return cc.REJECTED, "instantiate_witness: σ-applied callee is not a function", nil, nil end
		local ret = applied.ret or ({ fixed = {} } --[[: Ret ]])
		local params = applied.params or ({ fixed = {} } --[[: Params ]])
		-- verify each argument premise was checked against σ-applied params.
		local call_args = node.args
		local nargs = type(call_args) == "table" and #call_args or 0
		local deps = {} --[[: Dependency[] ]]
		for i = 1, nargs do
			local prem = ev.inputs[i]
			if not prem then return cc.REJECTED, "instantiate_witness missing an argument premise", nil, nil end
			if not cc.is_accepted(prem) then return cc.UNKNOWN, nil, nil, nil end
			local apr = read_typing(cc, prem, "checks_against")
			if not apr then return cc.REJECTED, "instantiate_witness argument premise is not checks_against", nil, nil end
			local want_param --[[: Ty | nil ]]
			if i <= #params.fixed then want_param = params.fixed[i] else want_param = params.vararg end
			if not want_param or not ty_eq(apr.type, want_param) then
				return cc.REJECTED, "instantiate_witness: argument " .. i .. " not checked against σ-applied param", nil, nil
			end
			deps[#deps + 1] = dep_claim(claim.id, prem)
		end
		-- the asserted call type equals σ-applied R's first slot.
		local result --[[: Ty ]]
		if #ret.fixed >= 1 then result = ret.fixed[1] else result = G.nil_() end
		if not ty_eq(result, want_ty) then
			return cc.REJECTED, "instantiate_witness: asserted type does not match σ-applied return", nil, nil
		end
		return accept(deps, { trust_note() })

	-- ── trusted_signature (stdlib / FFI / cross-module / force-cast boundary) ──
	elseif method == "trusted_signature" then
		-- Admit a has_type / checks_against through a VISIBLE trust boundary
		-- recorded as a trusted_boundary dependency (verbatim trusted_type_axiom).
		local payload = ev.result
		local tb_id = type(payload) == "table" and arg_id(payload.trust) or nil
		if not tb_id then return cc.REJECTED, "trusted_signature missing trust boundary", nil, nil end
		local tb = cc.state.trust_boundaries[A.idk(tb_id)]
		if not tb then return cc.REJECTED, "trusted_signature references unknown trust boundary", nil, nil end
		return cc.ACCEPTED, nil, { dep_trust(claim.id, tb.id), dep_artifact(claim.id, nref) }, { tb, trust_note() }
	end

	return cc.UNKNOWN, "unknown " .. predicate .. " method: " .. tostring(method), nil, nil
end

-- ── Registry entry (the lambda-rung contract: pinned inputs per version) ─────
--: (SemanticsRegistry) -> (boolean, string | nil)
function M.register(registry)
	return A.register(registry, {
		id = M.ID,
		version = M.VERSION,
		claim_predicates = { "has_type", "checks_against", "subtype", "narrows", "well_typed_type" },
		observation_predicates = { "syntax", "annotation" },
		evidence_methods = {
			"synth_lit", "synth_var", "synth_call", "synth_table", "synth_index",
			"synth_function", "synth_and_or_not",
			"check_against", "check_cast",
			"subtype_witness", "instantiate_witness", "narrow_guard",
			"type_shape_check", "trusted_signature",
		},
		trusted_methods = { "trusted_signature" },
		checker = M.checker,
	})
end

return M

