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
-- This file hosts Passes 2–4 of the mechanization (§8): the synthesis/checking
-- evidence methods, the registry entry, `trusted_signature`, `instantiate_witness`,
-- and the `type_shape_check` well-formedness (incl. μ contractiveness, §9.3
-- finding 1) [Pass 2]; the flow-narrowing layer (`narrow_guard`, narrows) [Pass 3];
-- and the `for-in pairs`/`ipairs` + numeric-`for` loop-variable typing
-- (`synth_loop_var`, `synth_numeric_for_var`, §5.2) [Pass 4]. Loop variables bind
-- directly from the iterated table's key/value types — no `$PairsReturn`-style
-- intrinsic (the slice has none; §9.1).
--
-- Errors are (rejected result class) / nil returns; the checker never throws for
-- data errors.

local A = require("lib.type.analysis")
local G = require("lib.type.analysis.slice_ty")
local TA = require("lib.type.analysis.slice_ty_arg")
local SUB = require("lib.type.analysis.slice_subtype")
local NAR = require("lib.type.analysis.slice_narrow")

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

-- Build a narrows(Γ, guard_ref, x, T_true, T_false) claim (§2.2). The flow layer's
-- positive claim: under Γ, the guard in `guard_ref` refines variable `x` to T_true
-- on the truthy path and T_false on the falsy path. Γ is a raw SliceCtx; x is the
-- refined variable name; T_true/T_false are interned Ty (encoded to portable form).
--: (Id, SliceCtx, Id, string, Ty, Ty) -> Claim
function M.narrows_claim(id, ctx, guard_ref, x, t_true, t_false)
	return A.claim({ id = id, semantics = M.ID, predicate = "narrows",
		args = { ctx = raw_ctx_to_arg(ctx), guard = { space = guard_ref.space, key = guard_ref.key },
			x = x, t_true = TA.encode(t_true), t_false = TA.encode(t_false) } })
end

-- ── Structural Ty identity via the interner ──────────────────────────────────
-- Two interned Ty are equal iff their tids match (slice_ty guarantees structural
-- identity ⇒ tid identity). This is the slice's `type_eq`.
--: (Ty, Ty) -> boolean
local function ty_eq(a, b) return a.tid == b.tid end

M.ty_eq = ty_eq

-- ── Well-formedness gate (audit round 1, finding 1) ──────────────────────────
-- Well-formedness is a HARD PRECONDITION of every type-consuming evidence method.
-- A non-contractive μ (e.g. `μX.(number | X)`) reads as TOP in the cycle-guarded
-- subtype relation, so it MUST NOT be allowed to enter `subtype_witness`,
-- `has_type`/`checks_against`, `instantiate_witness`, or `narrow_guard`. The gate
-- is at the claim/method ENTRY (per the §9.3 performance note), never inside the
-- relation's recursion. `TA.well_formed` also rejects degenerate μ whose binder
-- never occurs (`μX.never`). Reject the evidence with a diagnostic; never proceed.
--: (Ty) -> boolean
local function wf(ty) return TA.well_formed(ty) end

M.wf = wf

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
		local li = G.lit_int(v) -- (nil on a non-integer-valued literal, audit r1 finding 2)
		return li
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

-- ── Loop-variable typing (for-in pairs/ipairs; numeric for, §5.2) ────────────
--
-- `for-in` over `pairs(t)` / `ipairs(t)` is the ONLY for-in form in v1, and it is
-- typed by binding the loop variables DIRECTLY from the table's key/value types —
-- the trusted generic stdlib signature realized without a `$PairsReturn`-style
-- match-type intrinsic (the slice has none; §1.4, §9.1). `pairs<T>` over a table
-- yields (KeyType, ValueType); `ipairs<T>` over a table yields (integer, ValueType).
-- The body is checked under Γ extended with k:key-type, v:value-type.
--
-- pairs_kv(T): the (key, value) types pairs() binds over a table type T.
--   - indexer(K, V)              ⇒ (K, V)
--   - rec_with_indexer(.., K, V) ⇒ (string | K, fieldUnion | V)   (named keys are strings)
--   - rec (closed/open)          ⇒ (string, fieldValueUnion)       (or (string, unknown) if open/empty)
--   - union/mu                   ⇒ distribute / unfold
-- Returns nil if T is not a table type (pairs over a non-table is a type error).
local pairs_kv --[[: (Ty) -> ({ key: Ty, val: Ty }) | nil ]]

--: (Ty) -> ({ key: Ty, val: Ty }) | nil
pairs_kv = function(t)
	local k = t.kind
	if k == "mu" then return pairs_kv(G.unfold(t)) end
	if k == "indexer" then
		if not t.key or not t.val then return nil end
		return { key = t.key, val = t.val }
	end
	if k == "union" then
		-- distribute: pairs over a union of tables yields the union of key/value types.
		local ms = t.members or {}
		local keys = {} --[[: Ty[] ]]
		local vals = {} --[[: Ty[] ]]
		for i = 1, #ms do
			local kv = pairs_kv(ms[i])
			if not kv then return nil end
			keys[#keys + 1] = kv.key
			vals[#vals + 1] = kv.val
		end
		if #keys == 0 then return nil end
		return { key = G.union(keys), val = G.union(vals) }
	end
	if k == "rec" or k == "rec_with_indexer" then
		local fields = t.fields or {}
		local keys = {} --[[: Ty[] ]]
		local vals = {} --[[: Ty[] ]]
		if #fields > 0 then
			keys[#keys + 1] = G.string() -- named keys are strings
			for i = 1, #fields do vals[#vals + 1] = fields[i].ty end
		end
		if k == "rec_with_indexer" and t.key and t.val then
			keys[#keys + 1] = t.key
			vals[#vals + 1] = t.val
		end
		if t.rows == "open" then
			-- an open row carries unlisted fields of unknown value (the open-row rule).
			keys[#keys + 1] = G.string()
			vals[#vals + 1] = G.unknown()
		end
		if #keys == 0 then
			-- a closed, empty record: no keys to iterate. v1 types this as (string, never)
			-- — pairs over it produces nothing, so the value type is uninhabited.
			return { key = G.string(), val = G.never() }
		end
		return { key = G.union(keys), val = G.union(vals) }
	end
	return nil
end

M.pairs_kv = pairs_kv

-- ipairs(T): always (integer, valueType). The value type is the array-element type:
-- the indexer value when keys include integers, else the field-value union. v1
-- derives it from the indexer part (the array tail) when present, else from pairs_kv.
--: (Ty) -> ({ key: Ty, val: Ty }) | nil
local function ipairs_kv(t)
	local kv = pairs_kv(t)
	if not kv then return nil end
	return { key = G.integer(), val = kv.val }
end

M.ipairs_kv = ipairs_kv

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

-- ── Guard decoding (the narrowing layer's syntax → refinement input) ─────────
--
-- A Guard node (slice_narrow.lua) rides an artifact as portable data: its `lit`
-- fields are PTy (literal singletons of the comparison). decode_guard re-interns
-- every embedded `lit` to a Ty so the pure `NAR.refine` can run; it validates the
-- guard shape (parse-not-cast) and returns nil on any malformed node. The decoded
-- tree mirrors the Guard grammar with `lit` fields swapped to interned Ty.
local decode_guard --[[: (unknown) -> Guard | nil ]]

--: (unknown) -> Guard | nil
decode_guard = function(node)
	if type(node) ~= "table" then return nil end
	local g = node.g
	if type(g) ~= "string" then return nil end
	if g == "not" then
		local inner = decode_guard(node.inner)
		if not inner then return nil end
		return { g = "not", inner = inner }
	end
	if g == "and" or g == "or" then
		local l = decode_guard(node.left)
		local r = decode_guard(node.right)
		if not l or not r then return nil end
		return { g = g, left = l, right = r }
	end
	local var = node.var
	if type(var) ~= "string" then return nil end
	if g == "truthy" then return { g = "truthy", var = var } end
	if g == "nil_eq" then return { g = "nil_eq", var = var, eq = node.eq == true } end
	if g == "type_eq" then
		local tyname = node.tyname
		if type(tyname) ~= "string" then return nil end
		return { g = "type_eq", var = var, tyname = tyname }
	end
	if g == "lit_eq" then
		local lit = TA.decode(node.lit)
		if not lit then return nil end
		return { g = "lit_eq", var = var, lit = lit }
	end
	if g == "tag_eq" then
		local field = node.field
		if type(field) ~= "string" then return nil end
		local lit = TA.decode(node.lit)
		if not lit then return nil end
		return { g = "tag_eq", var = var, field = field, lit = lit }
	end
	return nil
end

M.decode_guard = decode_guard

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
		-- well-formedness is a hard precondition (audit round 1, finding 1): a
		-- non-contractive μ reads as top in the relation, so reject before deciding.
		if not wf(pair.a) or not wf(pair.b) then
			return cc.REJECTED, "subtype operand is not well-formed (non-contractive or degenerate μ)", nil, nil
		end
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

	-- ── narrows (the flow-narrowing layer, §4) ───────────────────────────────
	if predicate == "narrows" then
		if method ~= "narrow_guard" then
			return cc.UNKNOWN, "unknown narrows method: " .. tostring(method), nil, nil
		end
		-- args: ctx (Γ), guard (artifact ref), x (refined var), t_true, t_false.
		local nctx = parse_ctx(args.ctx)
		local gref = arg_id(args.guard)
		local x = args.x
		local want_true = TA.decode(args.t_true)
		local want_false = TA.decode(args.t_false)
		if not nctx then return cc.REJECTED, "narrows context is malformed", nil, nil end
		if not gref then return cc.REJECTED, "narrows missing guard ref", nil, nil end
		if type(x) ~= "string" then return cc.REJECTED, "narrows missing refined variable name", nil, nil end
		if not want_true or not want_false then return cc.REJECTED, "narrows missing/malformed refinement type", nil, nil end
		-- well-formedness is a hard precondition (audit round 1, finding 1).
		if not want_true or not want_false or not wf(want_true) or not wf(want_false) then
			return cc.REJECTED, "narrows refinement type is not well-formed", nil, nil
		end
		-- premise: has_type(Γ, x_node, T) — the synthesized PRE-GUARD type of x.
		-- (The producer supplies the one has_type premise establishing T; it must be
		--  a has_type whose asserted type is the pre-guard type of the refined var.)
		if #ev.inputs ~= 1 then return cc.REJECTED, "narrow_guard requires one has_type premise (the pre-guard type of x)", nil, nil end
		local prem = ev.inputs[1]
		if not cc.is_accepted(prem) then return cc.UNKNOWN, nil, nil, nil end
		local pr = read_typing(cc, prem, "has_type")
		if not pr then return cc.REJECTED, "narrow_guard premise is not a has_type claim", nil, nil end
		-- premise context must equal this claim's context (the pre-guard Γ).
		if A._serialize(ctx_to_arg(nctx)) ~= A._serialize(ctx_to_arg(pr.ctx)) then
			return cc.REJECTED, "narrow_guard premise context must match the conclusion's", nil, nil
		end
		-- the refined variable must be bound to the premise's type in Γ (the premise
		-- establishes x's pre-guard type; it must agree with x's binding).
		local bound = ctx_lookup(nctx, x)
		if not bound then return cc.REJECTED, "narrow_guard: refined variable '" .. x .. "' not bound in context", nil, nil end
		if not ty_eq(bound, pr.type) then
			return cc.REJECTED, "narrow_guard: premise type is not the pre-guard type of '" .. x .. "'", nil, nil
		end
		-- parse the guard syntax and run the pure refinement.
		local gnode = node_of(cc, gref)
		local guard = decode_guard(gnode)
		if not guard then return cc.REJECTED, "narrow_guard: guard syntax is malformed or outside v1", nil, nil end
		local t_true, t_false = NAR.refine(guard, x, pr.type)
		if not t_true or not t_false then return cc.REJECTED, "narrow_guard: guard does not refine '" .. x .. "'", nil, nil end
		if not ty_eq(t_true, want_true) then
			return cc.REJECTED, "narrow_guard: asserted truthy refinement does not match the positive decomposition", nil, nil
		end
		if not ty_eq(t_false, want_false) then
			return cc.REJECTED, "narrow_guard: asserted falsy refinement does not match the sound-wider approximation", nil, nil
		end
		return cc.ACCEPTED, nil, { dep_claim(claim.id, prem), dep_artifact(claim.id, gref) }, { trust_note() }
	end

	-- ── has_type / checks_against ────────────────────────────────────────────
	if predicate ~= "has_type" and predicate ~= "checks_against" then
		return cc.REJECTED, "unknown claim predicate: " .. tostring(claim.predicate), nil, nil
	end

	-- trusted_signature is handled BEFORE the type-decode preamble: a trusted
	-- boundary admits the claim through visible trust precisely because the slice
	-- does NOT decode/check the asserted type. This is what lets a generic stdlib
	-- signature (whose type carries FREE tyvars, which do not intern) ride a
	-- has_type claim — its raw PTy `type` arg is then bound to a call site by
	-- `instantiate_witness` (audit round 1, finding 5). All NON-trusted methods
	-- below require a decodable, well-formed type (the WF gate, finding 1).
	if method == "trusted_signature" then
		local nref0 = arg_id(args.node)
		if not nref0 then return cc.REJECTED, predicate .. " missing node ref", nil, nil end
		local payload = ev.result
		local tb_id = type(payload) == "table" and arg_id(payload.trust) or nil
		if not tb_id then return cc.REJECTED, "trusted_signature missing trust boundary", nil, nil end
		local tb = cc.state.trust_boundaries[A.idk(tb_id)]
		if not tb then return cc.REJECTED, "trusted_signature references unknown trust boundary", nil, nil end
		return cc.ACCEPTED, nil, { dep_trust(claim.id, tb.id), dep_artifact(claim.id, nref0) }, { tb, trust_note() }
	end

	local ctx = parse_ctx(args.ctx)
	local nref = arg_id(args.node)
	local want_ty = TA.decode(args.type)
	if not ctx then return cc.REJECTED, predicate .. " context is malformed", nil, nil end
	if not nref then return cc.REJECTED, predicate .. " missing node ref", nil, nil end
	if not want_ty then return cc.REJECTED, predicate .. " missing/malformed type", nil, nil end
	-- well-formedness is a hard precondition (audit round 1, finding 1): a
	-- non-contractive/degenerate μ must not enter a typing judgment.
	if not wf(want_ty) then
		return cc.REJECTED, predicate .. " asserted type is not well-formed (non-contractive or degenerate μ)", nil, nil
	end
	-- every binding in Γ must also be well-formed (a refined/bound type rides Γ
	-- into downstream judgments; an ill-formed binding would leak through).
	for i = 1, #ctx do
		if not wf(ctx[i].type) then
			return cc.REJECTED, predicate .. " context binding '" .. ctx[i].name .. "' is not well-formed", nil, nil
		end
	end
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
		-- BIND G TO THE CALLEE (audit round 1, finding 5). §2.4's input is
		-- `has_type(Γ, f_node, G)`: the FIRST premise must establish the function
		-- node's type, and the payload's portable generic G must structurally EQUAL
		-- that premise's asserted type — otherwise a fabricated generic gives any
		-- call any return type. A generic callee carries FREE tyvar nodes, which do
		-- not intern, so its has_type premise is established via `trusted_signature`
		-- (the stdlib generic signature) and carries the generic as its raw PTy
		-- `type` arg. We read that raw PTy and compare it structurally to
		-- payload.generic; we do NOT decode it (free tyvars are not interner-valid).
		if #ev.inputs < 1 then return cc.REJECTED, "instantiate_witness requires the has_type(f_node, G) premise first", nil, nil end
		local fn_prem = ev.inputs[1]
		if not cc.is_accepted(fn_prem) then return cc.UNKNOWN, nil, nil, nil end
		local fn_claim = cc.get_claim(fn_prem)
		if not fn_claim or fn_claim.predicate ~= "has_type" then
			return cc.REJECTED, "instantiate_witness first premise is not a has_type claim for the callee", nil, nil
		end
		local fn_cargs = fn_claim.args
		if type(fn_cargs) ~= "table" then return cc.REJECTED, "instantiate_witness callee premise has malformed args", nil, nil end
		-- the premise must be for THIS call's function node.
		local fnode_ref = arg_id(node.fn)
		local prem_node = arg_id(fn_cargs.node)
		if not fnode_ref or not prem_node or prem_node.space ~= fnode_ref.space or prem_node.key ~= fnode_ref.key then
			return cc.REJECTED, "instantiate_witness callee premise is not for this call's function node", nil, nil
		end
		-- the premise context must equal this claim's context.
		local fn_pctx = parse_ctx(fn_cargs.ctx)
		if not fn_pctx then return cc.REJECTED, "instantiate_witness callee premise context is malformed", nil, nil end
		if A._serialize(ctx_to_arg(fn_pctx)) ~= A._serialize(ctx_to_arg(ctx)) then
			return cc.REJECTED, "instantiate_witness callee premise context must match the conclusion's", nil, nil
		end
		-- payload.generic must structurally EQUAL the premise's asserted (generic) type.
		if A._serialize(generic) ~= A._serialize(fn_cargs.type) then
			return cc.REJECTED, "instantiate_witness: payload generic does not match the callee's declared type (fabricated generic)", nil, nil
		end
		local subst = {} --[[: { [string]: Ty } ]]
		for name, pty in pairs(praw) do
			local d = TA.decode(pty)
			if not d then return cc.REJECTED, "instantiate_witness σ has a malformed type", nil, nil end
			if type(name) == "string" then subst[name] = d end
		end
		local applied = TA.apply_subst_pty(generic, subst)
		if not applied then return cc.REJECTED, "instantiate_witness: σ application/decode failed", nil, nil end
		if not wf(applied) then return cc.REJECTED, "instantiate_witness: σ-applied callee is not well-formed", nil, nil end
		if applied.kind ~= "fn" then return cc.REJECTED, "instantiate_witness: σ-applied callee is not a function", nil, nil end
		local ret = applied.ret or ({ fixed = {} } --[[: Ret ]])
		local params = applied.params or ({ fixed = {} } --[[: Params ]])
		-- verify each argument premise was checked against σ-applied params. The
		-- argument premises follow the callee premise (inputs[2..]).
		local call_args = node.args
		local nargs = type(call_args) == "table" and #call_args or 0
		local deps = { dep_claim(claim.id, fn_prem) } --[[: Dependency[] ]]
		for i = 1, nargs do
			local prem = ev.inputs[i + 1]
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

	-- ── synth_loop_var (for-in pairs/ipairs loop variable, §5.2) ──
	-- A loop-variable node synthesizes its type from the iterated table's type.
	-- node: { t="loop_var", iter="pairs"|"ipairs", table=NodeRef, slot=1|2 }.
	-- premise: has_type(Γ, table_node, T) — the iterated table's type. The loop
	-- vars bind DIRECTLY from T's key/value types (no $PairsReturn intrinsic).
	elseif method == "synth_loop_var" then
		if node.t ~= "loop_var" then return cc.REJECTED, "synth_loop_var applied to a non-loop-var node", nil, nil end
		local iter = node.iter
		local slot = node.slot
		if type(iter) ~= "string" then return cc.REJECTED, "synth_loop_var: missing iterator kind", nil, nil end
		if iter ~= "pairs" and iter ~= "ipairs" then return cc.REJECTED, "synth_loop_var: iterator must be pairs or ipairs (general iterators are outside v1)", nil, nil end
		if slot ~= 1 and slot ~= 2 then return cc.REJECTED, "synth_loop_var: slot must be 1 (key) or 2 (value)", nil, nil end
		if #ev.inputs ~= 1 then return cc.REJECTED, "synth_loop_var requires one has_type premise (the iterated table)", nil, nil end
		local prem = ev.inputs[1]
		if not cc.is_accepted(prem) then return cc.UNKNOWN, nil, nil, nil end
		local pr = read_typing(cc, prem, "has_type")
		if not pr then return cc.REJECTED, "synth_loop_var premise is not a has_type claim", nil, nil end
		if A._serialize(ctx_to_arg(ctx)) ~= A._serialize(ctx_to_arg(pr.ctx)) then
			return cc.REJECTED, "synth_loop_var premise context must match the conclusion's", nil, nil
		end
		local tref = arg_id(node.table)
		if not tref or tref.space ~= pr.node.space or tref.key ~= pr.node.key then
			return cc.REJECTED, "synth_loop_var premise node is not the iterated table", nil, nil
		end
		local kv --[[: ({ key: Ty, val: Ty }) | nil ]]
		if iter == "pairs" then kv = pairs_kv(pr.type) else kv = ipairs_kv(pr.type) end
		if not kv then return cc.REJECTED, "synth_loop_var: " .. iter .. " applied to a non-table type", nil, nil end
		local bound --[[: Ty ]]
		if slot == 1 then bound = kv.key else bound = kv.val end
		if not ty_eq(bound, want_ty) then
			return cc.REJECTED, "synth_loop_var: asserted type does not match the loop variable's key/value type", nil, nil
		end
		return accept({ dep_claim(claim.id, prem) }, { trust_note() })

	-- ── synth_numeric_for_var (numeric for i = a, b, c, §5.2) ──
	-- The control variable of a numeric `for i = a, b, c do` binds `i : integer | number`
	-- per the doc's rule (the loop runs over numeric values; the precise subkind
	-- depends on the bounds, which v1 does not flow-track). node: { t="numeric_for_var" };
	-- no premises (the bound type is fixed by the loop form).
	elseif method == "synth_numeric_for_var" then
		if node.t ~= "numeric_for_var" then return cc.REJECTED, "synth_numeric_for_var applied to a non-loop-control node", nil, nil end
		local bound = G.union({ G.integer(), G.number() })
		if not ty_eq(bound, want_ty) then
			return cc.REJECTED, "synth_numeric_for_var: the numeric-for control variable is integer | number", nil, nil
		end
		return accept({}, { trust_note() })
	end

	-- (trusted_signature is handled before the decode preamble above — see the
	-- comment there; it never reaches this point.)

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
			"synth_loop_var", "synth_numeric_for_var",
			"type_shape_check", "trusted_signature",
		},
		trusted_methods = { "trusted_signature" },
		checker = M.checker,
	})
end

return M

