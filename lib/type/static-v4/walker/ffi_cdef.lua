-- Walker sub-phase G — FFI cdef integration.
--
-- Per docs/typechecker-ast-walker-design.md §9. This module recognises
-- the call-site shape `ffi.cdef[[ ... ]]` and populates the `$FfiC`
-- intrinsic table (the closed record bound to the `C` field of the `ffi`
-- module value).
--
-- Reuses the existing cdef parser (`lib/type/static/cdecl_parse.lua`)
-- verbatim. The parser yields a list of declaration descriptors:
--
--   { decl = "func"|"var"|"typedef"|"struct"|"enum_val",
--     name_id = <intern id>, type = CTypeDesc }
--
-- The walker's contribution is:
--
--   1. Call-site shape match — callee is `ffi.cdef` (NODE_FIELD_EXPR over
--      identifier `ffi`, key `"cdef"`) or `ffi["cdef"]` (NODE_INDEX_EXPR
--      with string literal key); argument list is a single NODE_LITERAL of
--      LIT_STRING. Anything else (non-literal argument, missing argument,
--      multiple arguments) is rejected loudly.
--   2. Type translation — CTypeDesc → V4Type per the table in design §9
--      (primitives, pointers, structs, function pointers). The reference
--      table is `lib/type/static/cdef.lua` (legacy v3); we re-derive the
--      mapping against v4 type constructors rather than reusing the v3
--      translator, which writes into a different type representation.
--   3. `$FfiC` accumulation — `ffi` is bound in the env to a record
--      containing a `C` field of `V.rec(..., /*open=*/false, nil)`. Each
--      cdef call returns a NEW env in which `ffi.C` is replaced by a new
--      closed record carrying the union of previous and new declarations.
--      Multiple cdef blocks accumulate naturally via this re-binding.
--
-- Closed-record semantics give the no-ambient-globals rule (CLAUDE.md):
-- `ffi.C.undeclared_symbol` is a closed-record-missing-field error from
-- v4's index reducer. The walker does not need a special case.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Intentionally annotation-free; same rationale as functions.lua /
-- statements.lua / indexed_access.lua (cross-module --:: alias
-- resolution limitation documented in walker/README.md).

local V       = require("lib.type.static-v4")
local E       = require("lib.type.static-v4.walker.env")
local D       = require("lib.type.static-v4.walker.diag")
local defs    = require("lib.type.static.defs")
local cdecl_parse = require("lib.type.static.cdecl_parse")
local intern_mod  = require("lib.type.static.intern")

local _types  = require("lib.type.static-v4.types")
local _ = _types

-- Pre-interned primitives, with the same runtime guard pattern used in
-- functions.lua / indexed_access.lua so the typechecker sees them as
-- non-nil at use sites.
local INT_TY  = V.prim("integer")
local NUM_TY  = V.prim("number")
local NIL_TY  = V.prim("nil")
local STR_TY  = V.prim("string")
local BOOL_TY = V.prim("boolean")
local TOP_TY  = V.top()
if INT_TY == nil or NUM_TY == nil or NIL_TY == nil
		or STR_TY == nil or BOOL_TY == nil or TOP_TY == nil then
	error("v4 primitive unexpectedly nil")
end

local M = {}

-- ── Call-site shape detection ─────────────────────────────────────────────
--
-- The cdef call has the shape `ffi.cdef("...")` or `ffi.cdef[[...]]`. Both
-- forms parse as NODE_CALL_EXPR over a NODE_FIELD_EXPR or NODE_INDEX_EXPR
-- callee (Lua does not distinguish `f"x"` / `f[[x]]` / `f("x")` at the AST
-- level — the parser produces the same NODE_CALL_EXPR shape).

-- True iff `node` is `ffi.cdef` or `ffi["cdef"]`. The handler signature
-- types the AST as the walker's Node shape (open record with `tag`,
-- `line`, `col` and arbitrary further fields). Field-shape decoding
-- follows the same pattern as indexed_access.lua's call-shape match —
-- field access on the open record yields `unknown`, which the call site's
-- equality/comparison guards discharge.
local function is_ffi_cdef_callee(node)
	if node == nil then return false end
	local tag = node.tag
	if tag == defs.NODE_FIELD_EXPR then
		if node.key ~= "cdef" then return false end
		local tgt = node.target
		if tgt == nil or tgt.tag ~= defs.NODE_IDENTIFIER then return false end
		return tgt.name == "ffi"
	end
	if tag == defs.NODE_INDEX_EXPR then
		local key = node.key
		if key == nil or key.tag ~= defs.NODE_LITERAL then return false end
		if key.lit_kind ~= defs.LIT_STRING then return false end
		if key.value ~= "cdef" then return false end
		local tgt = node.target
		if tgt == nil or tgt.tag ~= defs.NODE_IDENTIFIER then return false end
		return tgt.name == "ffi"
	end
	return false
end

-- ── CTypeDesc → V4Type translation (design §9) ────────────────────────────
--
-- C primitives map to v4 primitives; pointers, structs and function types
-- get the representations the design dictates. This is a direct derivation
-- against the v4 constructors — we DO NOT reuse `lib/type/static/cdef.lua`'s
-- translator because that writes into the v3 arena-backed type repr; the
-- shape conversion is mechanical (≤60 LOC) so a parallel implementation is
-- the right choice (see CLAUDE.md "Multiple implementations" / "Abstraction
-- has a cost").

-- CTypeDesc (from cdecl_parse) is a recursive open record. Its fields
-- depend on the dispatch key `k`: `to` for pointers, `of` for arrays,
-- `fields` for structs, `params`/`ret`/`vararg` for functions. A
-- top-level `--::` alias mirroring this shape would re-trigger the
-- known cross-module alias-resolution limitation noted in env.lua's
-- baseline diagnostics; we therefore keep the translator
-- annotation-free, matching the convention used in functions.lua and
-- indexed_access.lua. The CTypeDesc shape is documented in
-- `lib/type/static/cdef.lua` (header comments) and `cdecl_parse.lua`.

local c_type_to_v4 -- forward decl; assigned below.

-- Build a Ptr<T> per typechecker-reference.md: an open record carrying [0]:
-- T plus the field structure of T (when T is a struct, the field access
-- syntax `ptr.field` reads through). v4 4a does not yet have intersection
-- distribution over the index reducer, so we model Ptr<T> as the open record
-- {[0]: T, ...} — `ptr[0]` resolves; field access on Ptr-to-struct is left
-- to the caller's discretion (the design accepts this minimal shape for
-- sub-phase G; the richer Ptr<T> = T & {[0]: T} variant is a later
-- contribution when v4 gains the supporting machinery).
local function make_ptr(inner)
	local zero_lit = V.literal("integer", 0)
	if zero_lit == nil then error("V.literal(integer, 0) unexpectedly nil") end
	-- Open record so callers can read the structurally-implied fields when
	-- the pointer targets a struct; explicit [0] dereference is encoded via
	-- an indexer. (A bare named-field approach would require a string-keyed
	-- "0" which is wrong — pointer deref is an integer-zero index.)
	return V.rec({}, true, V.indexer(zero_lit, inner))
end

-- Build Arr<T> = { [integer]: T } — array pointer.
local function make_arr(elem)
	return V.rec({}, false, V.indexer(INT_TY, elem))
end

-- Translate a struct CTypeDesc's `fields` list to a closed v4 rec. We pass
-- the raw `fields` array (not the descriptor) so the typechecker's per-
-- branch narrowing of `ctype` at the dispatch site doesn't force the
-- helper's inferred signature to demand the parent descriptor's shape.
-- Members without a name (anonymous embedded fields) are skipped.
local function struct_fields_to_v4(fields_in, pool)
	if type(fields_in) ~= "table" then
		-- Opaque struct (forward declaration). v4 has no opaque-cdata
		-- tag; represent as a closed rec with no fields — any field
		-- access errors, matching the runtime behaviour.
		return V.rec({}, false, nil)
	end
	local fields_out = {}
	for _, sf in ipairs(fields_in) do
		if type(sf) == "table" then
			local nm_id = sf.name_id
			-- name_id is an intern_id (integer) per cdecl_parse's contract;
			-- structurally we only know it's `unknown` here. Floor() yields
			-- an integer narrowing while accepting any numeric value.
			if type(nm_id) == "number" then
				local nm = intern_mod.get(pool, math.floor(nm_id))
				if type(nm) == "string" then
					local fty = c_type_to_v4(sf.type, pool)
					fields_out[nm] = fty
				end
			end
		end
	end
	return V.rec(fields_out, false, nil)
end

-- Translate a C function type's `(params, ret, vararg)` triple to V.fn.
-- C functions have no v4 effect-set equivalent (the FFI boundary is opaque
-- to the typechecker's effect tracking); effects = {} per §9. Variadic C
-- functions pose a representation gap — v4 4a has no spread-param syntax
-- for fns — so we encode the vararg by adding a trailing `top`-typed param
-- (the design notes this as the principled fallback until v4 grows native
-- variadic-fn support). As with struct_fields_to_v4 we accept the raw
-- fields rather than the parent descriptor to avoid per-branch narrowing
-- forcing the helper's inferred signature into shapes the caller can't
-- satisfy.
local function func_parts_to_v4(params_in, ret_desc, vararg, pool)
	local param_tys = {}
	if type(params_in) == "table" then
		for i, p in ipairs(params_in) do
			if type(p) == "table" then
				param_tys[i] = c_type_to_v4(p.type, pool)
			end
		end
	end
	if vararg then
		param_tys[#param_tys + 1] = TOP_TY
	end
	local ret_ty = NIL_TY
	if type(ret_desc) == "table" then
		local rd_k = ret_desc.k
		if type(rd_k) == "string" and rd_k ~= "void" then
			ret_ty = c_type_to_v4(ret_desc, pool)
		end
	end
	return V.fn(param_tys, ret_ty, nil)
end

-- Main translator. Recursive over pointers/typedefs; the cdef parser
-- pre-resolves typedef references when possible, but `k == "name"` may
-- occur for unresolved typedef references (we map them to `top` — the
-- least-precise type that doesn't lie about the value).
-- The dispatch reads `ctype.k` once and dispatches via a string-table.
-- Building the table per-call is hot-path-acceptable: cdef calls are rare,
-- and the dispatch keeps the typechecker from per-branch-narrowing `ctype`
-- to the literal type checked (`{k: "func"}` etc.) which would then make
-- the recursive sub-calls fail with "missing field" diagnostics.
c_type_to_v4 = function(ctype, pool)
	if ctype == nil then return TOP_TY end
	local k = ctype.k
	-- Primitive leaves: dispatched first via a string-keyed lookup so the
	-- typechecker sees a uniform return rather than a chain of narrowings.
	local prim = ({
		["void"]  = NIL_TY,
		["bool"]  = BOOL_TY,
		["int"]   = INT_TY,
		["char"]  = INT_TY, -- C `char` is integer-valued
		["enum"]  = INT_TY, -- enum constants are ints
		["float"] = NUM_TY,
		["union"] = TOP_TY, -- unions not safely representable as closed rec
		["name"]  = TOP_TY, -- unresolved typedef name
	})[k]
	if prim ~= nil then return prim end
	-- Compound dispatch. Each branch passes `ctype` through to a helper
	-- that consumes the full descriptor; the helpers are responsible for
	-- field-presence checking, so the typechecker's narrowing of `k` here
	-- does not constrain what `ctype` carries.
	if k == "ptr" then
		local to = ctype.to
		if to ~= nil then
			local tok = to.k
			if tok == "char" then return STR_TY end -- char* → string
			if tok == "void" then return TOP_TY end -- void* — opaque
			if tok == "func" then
				-- Function pointer: same type as the function itself.
				return func_parts_to_v4(to.params, to.ret, to.vararg, pool)
			end
			if tok == "struct" then
				return make_ptr(struct_fields_to_v4(to.fields, pool))
			end
		end
		-- Opaque pointer.
		return TOP_TY
	end
	if k == "arr" then
		if ctype.of == nil then return TOP_TY end
		return make_arr(c_type_to_v4(ctype.of, pool))
	end
	if k == "struct" then
		return struct_fields_to_v4(ctype.fields, pool)
	end
	if k == "func" then
		return func_parts_to_v4(ctype.params, ctype.ret, ctype.vararg, pool)
	end
	return TOP_TY
end

-- ── $FfiC accumulator ─────────────────────────────────────────────────────
--
-- The walker stores `ffi` in env.bindings as a record:
--
--   { cdef: (string) -> nil,
--     C:    V.rec({ <decl> = <type>, ... }, /*open=*/false, nil) }
--
-- Each `ffi.cdef[[...]]` call rebinds `ffi` with C replaced by a new closed
-- record containing the merged field set. The closed-ness gives the
-- undeclared-symbol-errors behaviour for free via v4's index reducer.

-- Extract the current `ffi.C` field map. Returns (fields_table, err). Fails
-- loudly if `ffi` is not bound, is not a rec, has no `C` field, or `C` is
-- not a rec — these all indicate prelude misuse, not a runtime concern.
local function read_ffi_c_fields(env)
	local ffi_ty = env.bindings["ffi"]
	if ffi_ty == nil then
		return nil,
			"ffi.cdef: `ffi` is not in scope (require `ffi` first)"
	end
	if ffi_ty.tag ~= "rec" then
		return nil,
			"ffi.cdef: `ffi` has non-record type " .. V.show(ffi_ty)
	end
	local c_ty = ffi_ty.fields["C"]
	if c_ty == nil then
		return nil,
			"ffi.cdef: `ffi.C` field is not present on the `ffi` binding"
	end
	if c_ty.tag ~= "rec" then
		return nil,
			"ffi.cdef: `ffi.C` has non-record type " .. V.show(c_ty)
	end
	return ffi_ty, c_ty
end

-- Build a new env with `ffi.C` replaced by a closed record containing
-- `merged_fields`. Other fields of the `ffi` binding (`cdef` itself, any
-- future API) are preserved.
local function rebind_ffi_c(env, ffi_ty, merged_fields)
	local new_c = V.rec(merged_fields, false, nil)
	local new_fields = {}
	for k, v in pairs(ffi_ty.fields) do new_fields[k] = v end
	new_fields["C"] = new_c
	local new_ffi = V.rec(new_fields, ffi_ty.open, ffi_ty.indexer)
	return E.bind(env, "ffi", new_ffi)
end

-- Process one cdef source string: parse it, translate decls, merge into
-- `ffi.C`. Returns (new_env, err). Typedef decls register as type aliases
-- — v4 4a does not yet have a named-alias scope on the env (sub-phase
-- C-of-walker did not introduce one), so typedef decls that have no
-- value-level binding are absorbed only insofar as later cdef declarations
-- referencing the typedef will pick up the parser's pre-resolved expansion.
-- This is the design's stance: the type alias side of typedef goes through
-- the cdef parser's typedef table, not through the walker env.
local function process_cdef_string(env, source)
	local ffi_ty, c_ty_or_err = read_ffi_c_fields(env)
	if ffi_ty == nil then
		-- c_ty_or_err is the error string here.
		return env, c_ty_or_err
	end
	local c_ty = c_ty_or_err
	-- Fresh intern pool per cdef call. The pool is needed only to recover
	-- declared names; it does NOT need to be shared across calls. A shared
	-- pool would let typedef references in a later cdef resolve from an
	-- earlier cdef's typedefs — that level of cross-call typedef sharing
	-- is a later contribution; sub-phase G's tests pass with per-call
	-- pools because each cdef string is self-contained.
	local pool = intern_mod.new()
	local ok, decls = pcall(cdecl_parse.parse, source, pool)
	if not ok then
		local msg = tostring(decls)
		return env, "ffi.cdef: parse failed: " .. msg
	end
	if type(decls) ~= "table" then
		return env, "ffi.cdef: parser returned non-table"
	end
	-- Merge existing C fields with new decls.
	local merged = {}
	for k, v in pairs(c_ty.fields) do merged[k] = v end
	for _, d in ipairs(decls) do
		local nm_id = d.name_id
		if nm_id ~= nil then
			local nm = intern_mod.get(pool, nm_id)
			if nm ~= nil then
				local dk = d.decl
				if dk == "func" or dk == "var" then
					merged[nm] = c_type_to_v4(d.type, pool)
				elseif dk == "enum_val" then
					-- Enum constants are integers accessible via ffi.C.
					merged[nm] = INT_TY
				end
				-- typedef / struct decls do not add symbols to ffi.C — they
				-- define type aliases, which v4 4a does not currently bind on
				-- the walker env. See module-level comment.
			end
		end
	end
	return rebind_ffi_c(env, ffi_ty, merged), nil
end

-- ── NODE_CALL_EXPR (overrides F) ─────────────────────────────────────────
--
-- F handles indexed callees and varargs. G layers on top: BEFORE F's
-- handler runs, we check for the `ffi.cdef("...")` shape; on match we
-- short-circuit with the cdef processing pass and return env-as-modified.
-- Non-cdef calls fall through to F's handler unchanged.
--
-- The shape match is intentionally conservative: argument count must be 1,
-- argument must be a NODE_LITERAL of LIT_STRING. A non-literal argument
-- (a variable, a concat, a function call) is rejected with a clear
-- message — static cdef analysis cannot proceed without the literal text.
-- This matches the documented behaviour in typechecker-reference.md.

local existing_call_handler -- captured at register-time

local function synth_call(node, env, solver)
	if is_ffi_cdef_callee(node.callee) then
		local args = node.args or ({})
		if #args ~= 1 then
			return nil, env, D.emit(env, D.E_FFI_CDEF,
				"ffi.cdef: expected exactly one argument (a string literal), got " ..
				tostring(#args))
		end
		local arg = args[1]
		if arg.tag ~= defs.NODE_LITERAL or arg.lit_kind ~= defs.LIT_STRING then
			return nil, env, D.emit(env, D.E_FFI_CDEF,
				"ffi.cdef: argument must be a string literal " ..
				"(dynamic cdef strings cannot be statically analysed)")
		end
		local source = arg.value
		if type(source) ~= "string" then
			return nil, env, D.emit(env, D.E_FFI_CDEF,
				"ffi.cdef: string literal has non-string value " .. type(source))
		end
		local new_env, err = process_cdef_string(env, source)
		if err ~= nil then
			return nil, new_env, D.emit(new_env, D.E_FFI_CDEF, tostring(err))
		end
		-- `ffi.cdef` returns nothing; produce nil to indicate a statement-
		-- shaped call. The caller (NODE_EXPR_STMT in the usual case) drops
		-- the synthesized type.
		return NIL_TY, new_env, nil
	end
	return existing_call_handler(node, env, solver)
end

-- ── registration ─────────────────────────────────────────────────────────

function M.register(W)
	-- Capture F's CALL_EXPR handler before replacing it; the wrapper
	-- delegates to it on non-cdef calls. Re-registration here is the
	-- standard sub-phase pattern (see indexed_access.lua's override
	-- approach).
	existing_call_handler = require("lib.type.static-v4.walker.indexed_access").synth_call_for_subphase_g
	if existing_call_handler == nil then
		error("walker sub-phase G: cannot capture sub-phase F's synth_call handler — " ..
			"indexed_access.lua does not expose synth_call_for_subphase_g")
	end
	W.register_synth(defs.NODE_CALL_EXPR, synth_call)
end

-- Exposed for sub-phase H (effects.lua) to wrap as a fallback. Sub-phase H
-- layers its intrinsic-call recognisers (error/pcall/xpcall) on top of
-- the FFI-aware handler; non-intrinsic, non-cdef calls fall through to
-- the captured handler. Same convention as indexed_access.lua's
-- `synth_call_for_subphase_g`.
M.synth_call_for_subphase_h = synth_call

-- Test hooks — exposed so the test suite can exercise the translator and
-- the call-shape recogniser directly without round-tripping through a full
-- walk.
M.is_ffi_cdef_callee = is_ffi_cdef_callee
M.c_type_to_v4       = c_type_to_v4
M.process_cdef_string = process_cdef_string

return M
