-- lib/declc/harvest.lua
-- Claim harvesters for the declarative-core composite: three generation
-- sources per docs/artifacts/2026-07-05-typechecker-declarative-core/
-- declarative-design.md's certified formulation ("a pool of graded
-- assumptions ... three generation sources, no source special-cased") and
-- declarative-core-draft.md §3's J4 rule families (Stated / Axiom / Belief).
--
--   harvest_stated(source, filename) -- (S-param)/(S-return), draft.md:76-79:
--     a `--:` function-type annotation on a definition mints one box-claim
--     per parameter slot (arrives(entry(f), x, T)) and one per return slot
--     (arrives(exit(f), j, T)).
--   harvest_axiom()                  -- (Axiom), draft.md:87-92: "a fixed
--     catalog of universal claims holds of every program" -- quoted
--     verbatim below per claim. Grade-independent of any file (matches the
--     zero-argument signature): these are claims about *every* program, not
--     instantiated at a concrete site, so no source text is needed to
--     produce them. Instantiating them against concrete program sites (e.g.
--     "which calls are under a handler-by-design") is exactly the missing
--     middle derivation layer -- Hole H1, open-threads.md -- and is left to
--     check.lua to report Open, not invented here.
--   harvest_mined(source, filename)  -- (Belief), draft.md:94-97 / H5,
--     open-threads.md: EXACTLY the two catalogued presupposing forms --
--     dereference (x.f / x[k] / x:m(...)) presupposes x non-nil; a guard
--     (if/elseif clause) presupposes both branches believed reachable. No
--     other mined forms are added, however tempting, per H5's own text:
--     "the notes supply no catalog of presupposing forms" beyond these two.
--
-- Reuse note (harvest_stated): this file requires lib.type.static.parse and
-- .ann READ-ONLY -- it never modifies them. Friction found integrating them,
-- worth recording for whoever builds H1's real derivation layer next:
--   - There is no standalone "annotation belongs to this parameter/return
--     slot" association step in the typechecker. lib/type/static/ann.lua's
--     parse_annotations only turns a raw {line -> {kind, content}} table
--     into parsed type_ids; site-association (which function a `--:`
--     annotation types) happens fused inside constrain.lua's full AST-walk
--     constraint generation (interleaved with unification, scope tracking,
--     etc.) and is not separable from that pipeline. This harvester
--     re-derives the association itself from the raw parse tree using the
--     repo convention that a `--:` annotation sits on the line immediately
--     before the definition it types -- a convention, not something
--     ann.lua/parse.lua assert as a contract.
--   - lib/type/static/types.lua's `M.display(ctx, tid)` (the typechecker's
--     own type-to-string printer) looked like a natural reuse target for
--     rendering a parsed annotation type back to a schema string, and its
--     Ctx argument's field names (`types`/`fields`/`lists`/`pool`) happen to
--     overlap with ann.lua's parse_annotations result -- but `display` has
--     no declared `--:` signature, so the typechecker infers its parameter
--     type structurally from the FULL checker Ctx (constrain.lua's
--     `new_ctx`), which carries dozens of fields (scope, err, def_sites,
--     type_at, ...) that parse_annotations's result never populates. A
--     partial Ctx is therefore not a valid argument under the inferred
--     type, even though the four fields `display` actually touches ARE
--     present. Reusing it read-only would require constructing a full
--     checker Ctx (constrain.generate's territory, not read-only parsing),
--     so this file renders types itself below (`render_type`) instead --
--     intentionally small, covering only the type shapes `--:` annotations
--     actually produce in this codebase (primitives, literals, unions,
--     intersections, functions, tables, named/nominal types).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band = bit.band

local parse_mod = require("lib.type.static.parse")
local defs = require("lib.type.static.defs")
local ann_mod = require("lib.type.static.ann")
local types_mod = require("lib.type.static.types")
local intern_mod = require("lib.type.static.intern")
local claim = require("lib.declc.claim")
--:: require "lib.declc.claim"

local M = {}

--:: HarvestClaims = { [integer]: Claim, ... }

---------------------------------------------------------------------------
-- render_type: minimal, read-only type-to-string printer.
-- See file header ("Reuse note") for why this doesn't call
-- lib/type/static/types.lua's M.display. `ann_result` is the table returned
-- by ann_mod.parse_annotations: { types, fields, lists, pool, ... }.
---------------------------------------------------------------------------

-- render_type/render_list are defined inside M.harvest_stated (below) as
-- closures over that call's `ann_result`, rather than at module level
-- taking `ann_result` as a parameter: `ann_result`'s real shape is inferred
-- structurally from `ann_mod.parse_annotations`'s return, and threading it
-- through an explicitly-typed top-level parameter would force widening it
-- to `unknown` (see file header "Reuse note" for the same shape-inference
-- issue with `types_mod.display`).

---------------------------------------------------------------------------
-- harvest_stated
---------------------------------------------------------------------------

--: (string, string | nil) -> (HarvestClaims | nil, string | nil)
function M.harvest_stated(source, filename)
	if type(source) ~= "string" then
		return nil, "harvest_stated: source must be a string"
	end
	local fname = filename or "?"
	local ok, pr_or_err = pcall(parse_mod.parse, source, fname)
	if not ok then
		return nil, "harvest_stated: parse error: " .. tostring(pr_or_err)
	end
	local pr = pr_or_err
	local ann_result = ann_mod.parse_annotations(pr.lexer.annotations, pr.pool, fname)
	local nodes, lists, pool = pr.nodes, pr.lists, pr.pool
	local out = {} --[[: HarvestClaims]]

	local ann_types, ann_fields, ann_lists, ann_pool =
		ann_result.types, ann_result.fields, ann_result.lists, ann_result.pool

	local render_type -- forward

	--: (integer, integer, string) -> string
	local function render_list(start, len, sep)
		local parts = {}
		for i = 0, len - 1 do
			parts[#parts + 1] = render_type(ann_lists:get(start + i))
		end
		return table.concat(parts, sep)
	end

	-- Minimal, read-only type-to-string printer. See file header ("Reuse
	-- note") for why this doesn't call lib/type/static/types.lua's
	-- M.display. Covers only the type shapes `--:` annotations actually
	-- produce in this codebase (primitives, literals, unions,
	-- intersections, functions, tables, named/nominal types).
	--: (integer) -> string
	render_type = function(tid)
		local t = ann_types:get(tid)
		local tag = t.tag
		if tag == defs.TAG_NIL then return "nil"
		elseif tag == defs.TAG_BOOLEAN then return "boolean"
		elseif tag == defs.TAG_NUMBER then return "number"
		elseif tag == defs.TAG_STRING then return "string"
		elseif tag == defs.TAG_INTEGER then return "integer"
		elseif tag == defs.TAG_ANY then return "any"
		elseif tag == defs.TAG_NEVER then return "never"
		elseif tag == defs.TAG_UNKNOWN then return "unknown"
		elseif tag == defs.TAG_CDATA then return "cdata"
		elseif tag == defs.TAG_LITERAL then
			local lk = types_mod.lit_kind(t)
			if lk == defs.LIT_STRING then
				return string.format("%q", intern_mod.get(ann_pool, types_mod.lit_str_id(t)) or "?")
			elseif lk == defs.LIT_INTEGER then
				return tostring(types_mod.lit_num_lo(t))
			elseif lk == defs.LIT_NUMBER then
				return tostring(defs.i32x2_to_double(types_mod.lit_num_lo(t), types_mod.lit_num_hi(t)))
			elseif lk == defs.LIT_BOOLEAN then
				return types_mod.lit_bool(t) ~= 0 and "true" or "false"
			else
				return "nil"
			end
		elseif tag == defs.TAG_UNION then
			return render_list(types_mod.agg_members_start(t), types_mod.agg_members_len(t), " | ")
		elseif tag == defs.TAG_INTERSECTION then
			return render_list(types_mod.agg_members_start(t), types_mod.agg_members_len(t), " & ")
		elseif tag == defs.TAG_TUPLE then
			return "(" .. render_list(types_mod.agg_members_start(t), types_mod.agg_members_len(t), ", ") .. ")"
		elseif tag == defs.TAG_FUNCTION then
			local ps = render_list(types_mod.fn_params_start(t), types_mod.fn_params_len(t), ", ")
			local rs = render_list(types_mod.fn_returns_start(t), types_mod.fn_returns_len(t), ", ")
			return "(" .. ps .. ") -> (" .. rs .. ")"
		elseif tag == defs.TAG_TABLE then
			local parts = {}
			local fs, fl = types_mod.tbl_fields_start(t), types_mod.tbl_fields_len(t)
			for i = 0, fl - 1 do
				local fe = ann_fields:get(ann_lists:get(fs + i))
				if fe.name_id >= 0 then
					local fname2 = intern_mod.get(ann_pool, fe.name_id) or "?"
					parts[#parts + 1] = fname2 .. ": " .. render_type(fe.type_id)
				end
			end
			local is, il = types_mod.tbl_indexers_start(t), types_mod.tbl_indexers_len(t)
			local i = 0
			while i < il do
				local key_tid = ann_lists:get(is + i)
				local val_tid = ann_lists:get(is + i + 1)
				parts[#parts + 1] = "[" .. render_type(key_tid) .. "]: " .. render_type(val_tid)
				i = i + 2
			end
			return "{ " .. table.concat(parts, ", ") .. " }"
		elseif tag == defs.TAG_NAMED then
			local name = intern_mod.get(ann_pool, types_mod.named_name_id(t)) or "?"
			local al = types_mod.named_args_len(t)
			if al > 0 then
				return name .. "<" .. render_list(types_mod.named_args_start(t), al, ", ") .. ">"
			end
			return name
		elseif tag == defs.TAG_NOMINAL then
			return intern_mod.get(ann_pool, t.data[0]) or "?"
		else
			return "<type:" .. tostring(tag) .. ">"
		end
	end

	--: (integer) -> string
	local function name_of(nid)
		local nd = nodes:get(nid)
		if nd.kind == defs.NODE_IDENTIFIER then
			return intern_mod.get(pool, nd.data[0]) or "?"
		elseif nd.kind == defs.NODE_FIELD_EXPR then
			return name_of(nd.data[0]) .. "." .. (intern_mod.get(pool, nd.data[1]) or "?")
		end
		return "<expr>"
	end

	--: (integer, integer) -> { [integer]: string, ... }
	local function param_names(ps, pl)
		local names = {} --: { [integer]: string, ... }
		for i = 0, pl - 1 do
			names[#names + 1] = intern_mod.get(pool, lists:get(ps + i)) or "?"
		end
		return names
	end

	--: (integer, string, integer, integer) -> nil
	local function emit_for_def(def_line, funcname, ps, pl)
		local ann_line = def_line - 1
		local res = ann_result.results[ann_line]
		if res == nil or res.kind ~= defs.ANN_TYPE then
			-- No `--:` annotation directly above this definition (or the
			-- line holds something other than a type annotation) -- nothing
			-- stated, not an error. Most functions in a file are
			-- unannotated; this is the expected common case, not a
			-- harvester bug.
			return
		end
		local t = ann_result.types:get(res.type_id)
		if t.tag ~= defs.TAG_FUNCTION then
			-- `--:` above a function definition that isn't itself a
			-- function type (e.g. annotates a preceding unrelated local).
			-- Skip rather than guess.
			return
		end
		local site = fname .. ":" .. tostring(def_line) .. ":" .. funcname
		local names = param_names(ps, pl)

		local fps, fpl = types_mod.fn_params_start(t), types_mod.fn_params_len(t)
		local n_params = fpl --: integer
		if pl < fpl then n_params = pl end
		for i = 0, n_params - 1 do
			local pt = ann_lists:get(fps + i)
			local ok2, schema_str = pcall(render_type, pt)
			if ok2 then
				local pname = names[i + 1] or ("arg" .. tostring(i + 1))
				local c = claim.new({
					site = site,
					slot = "entry:" .. pname,
					stratum = claim.STRATUM.PI1,
					modal = claim.MODAL.BOX,
					schema = schema_str,
					schema_key = schema_str,
					provenance = claim.PROVENANCE.STATED,
				})
				if c ~= nil then out[#out + 1] = c end
			end
		end

		local frs, frl = types_mod.fn_returns_start(t), types_mod.fn_returns_len(t)
		for j = 0, frl - 1 do
			local rt = ann_lists:get(frs + j)
			local ok3, schema_str = pcall(render_type, rt)
			if ok3 then
				local c = claim.new({
					site = site,
					slot = "exit:" .. tostring(j + 1),
					stratum = claim.STRATUM.PI1,
					modal = claim.MODAL.BOX,
					schema = schema_str,
					schema_key = schema_str,
					provenance = claim.PROVENANCE.STATED,
				})
				if c ~= nil then out[#out + 1] = c end
			end
		end
	end

	local walk_block -- forward

	--: (integer) -> nil
	local function visit_def(sid)
		local nd = nodes:get(sid)
		local k = nd.kind
		if k == defs.NODE_FUNC_DECL then
			emit_for_def(nd.line, name_of(nd.data[0]), nd.data[1], nd.data[2])
			walk_block(nd.data[3], nd.data[4])
		elseif k == defs.NODE_ASSIGN_STMT then
			local ts, vs, vl = nd.data[0], nd.data[2], nd.data[3]
			for j = 0, vl - 1 do
				local vid = lists:get(vs + j)
				local vnd = nodes:get(vid)
				if vnd.kind == defs.NODE_FUNC_EXPR then
					local tid = lists:get(ts + j)
					emit_for_def(nd.line, name_of(tid), vnd.data[0], vnd.data[1])
					walk_block(vnd.data[2], vnd.data[3])
				end
			end
		elseif k == defs.NODE_LOCAL_STMT then
			local ns, vs, vl = nd.data[0], nd.data[2], nd.data[3]
			for j = 0, vl - 1 do
				local vid = lists:get(vs + j)
				local vnd = nodes:get(vid)
				if vnd.kind == defs.NODE_FUNC_EXPR then
					local name_id = lists:get(ns + j)
					local funcname = intern_mod.get(pool, name_id) or "?"
					emit_for_def(nd.line, funcname, vnd.data[0], vnd.data[1])
					walk_block(vnd.data[2], vnd.data[3])
				end
			end
		elseif k == defs.NODE_IF_STMT then
			local cs, cl = nd.data[0], nd.data[1]
			for ci = 0, cl - 1 do
				local clid = lists:get(cs + ci)
				local cnd = nodes:get(clid)
				walk_block(cnd.data[1], cnd.data[2])
			end
			if band(nd.flags, defs.FLAG_HAS_ELSE) ~= 0 then
				walk_block(nd.data[2], nd.data[3])
			end
		elseif k == defs.NODE_DO_STMT then
			walk_block(nd.data[0], nd.data[1])
		elseif k == defs.NODE_WHILE_STMT then
			walk_block(nd.data[1], nd.data[2])
		elseif k == defs.NODE_REPEAT_STMT then
			walk_block(nd.data[1], nd.data[2])
		elseif k == defs.NODE_FOR_NUM then
			walk_block(nd.data[4], nd.data[5])
		elseif k == defs.NODE_FOR_IN then
			walk_block(nd.data[4], nd.data[5])
		end
	end

	--: (integer, integer) -> nil
	walk_block = function(stmts_start, stmts_len)
		for i = 0, stmts_len - 1 do
			visit_def(lists:get(stmts_start + i))
		end
	end

	local root_nd = nodes:get(pr.root)
	walk_block(root_nd.data[0], root_nd.data[1])
	return out, nil
end

---------------------------------------------------------------------------
-- harvest_axiom
---------------------------------------------------------------------------

-- The fixed universal-axiom catalog, quoted (near-verbatim) from
-- declarative-core-draft.md:87-92 ("(Axiom)"). Each entry below cites the
-- exact clause it comes from; nothing here is invented beyond that text.
-- site = "*" (universal: every program, not a concrete location) -- these
-- are program-generic per draft.md's own wording ("holds of every
-- program"), not per-site instantiations. Instantiating one against a
-- concrete call site (e.g. deciding which calls are "under a
-- handler-by-design") is exactly Hole H1's missing derivation layer; that
-- is check.lua's job to report Open on, not this harvester's job to guess.
local AXIOM_CATALOG = {
	{
		slot = "err-unintended",
		stratum = claim.STRATUM.PI1,
		modal = claim.MODAL.BOX,
		schema = "err-events are unintended: no run reaches err(s,_) for s not under a handler-by-design",
	},
	{
		slot = "reachable",
		stratum = claim.STRATUM.SIGMA1,
		modal = claim.MODAL.DIAMOND,
		schema = "code is meant to run: some run reaches s",
	},
	{
		slot = "consumed",
		stratum = claim.STRATUM.PI1,
		modal = claim.MODAL.BOX,
		schema = "produced values are meant to matter: every run consumes the value produced at a value-producing s",
	},
	{
		slot = "paired",
		stratum = claim.STRATUM.PI1,
		modal = claim.MODAL.BOX,
		schema = "paired resources close: every opened resource is eventually closed",
	},
	{
		slot = "house",
		stratum = claim.STRATUM.PI1,
		modal = claim.MODAL.BOX,
		schema = "house axioms: caps-first (no ambient io), errors return (nil, errmsg)",
	},
}

--: () -> (HarvestClaims, nil)
function M.harvest_axiom()
	local out = {} --[[: HarvestClaims]]
	for _, entry in ipairs(AXIOM_CATALOG) do
		local c = claim.new({
			site = "*",
			slot = entry.slot,
			stratum = entry.stratum,
			modal = entry.modal,
			schema = entry.schema,
			schema_key = entry.schema,
			provenance = claim.PROVENANCE.AXIOM,
		})
		if c ~= nil then out[#out + 1] = c end
	end
	return out, nil
end

---------------------------------------------------------------------------
-- harvest_mined
---------------------------------------------------------------------------

-- The two H5-catalogued presupposing forms, draft.md:94-97, and no others:
--   (Belief-deref)  x.f / x[k] / x:m(...) at s  ⊢  arrives(s, x, non-nil) @ belief  (box)
--   (Belief-guard)  an if/elseif clause at s     ⊢  reachable(then-branch) @ belief (diamond)
--                   (and, when an else exists)      reachable(else-branch) @ belief (diamond)
--
-- Scoping note: draft.md's own example for Belief-deref is field access
-- (`x.f`); this harvester also fires on `x[k]` (NODE_INDEX_EXPR, same
-- presupposition -- x must be non-nil to index) and on method-call
-- receivers (NODE_METHOD_CALL: `x:m(...)` dereferences x exactly as
-- `x.m(...)` would). That is broader *instantiation* of the same one form,
-- not a third mined form.

--: (string, string | nil) -> (HarvestClaims | nil, string | nil)
function M.harvest_mined(source, filename)
	if type(source) ~= "string" then
		return nil, "harvest_mined: source must be a string"
	end
	local fname = filename or "?"
	local ok, pr_or_err = pcall(parse_mod.parse, source, fname)
	if not ok then
		return nil, "harvest_mined: parse error: " .. tostring(pr_or_err)
	end
	local pr = pr_or_err
	local nodes, lists, pool = pr.nodes, pr.lists, pr.pool
	local out = {} --[[: HarvestClaims]]

	--: (integer) -> string
	local function deref_base_name(nid)
		local nd = nodes:get(nid)
		if nd.kind == defs.NODE_IDENTIFIER then
			return intern_mod.get(pool, nd.data[0]) or "?"
		elseif nd.kind == defs.NODE_FIELD_EXPR then
			return deref_base_name(nd.data[0]) .. "." .. (intern_mod.get(pool, nd.data[1]) or "?")
		end
		return "<expr>"
	end

	--: (integer, integer) -> nil
	local function emit_deref(nid, base_nid)
		local nd = nodes:get(nid)
		local base_name = deref_base_name(base_nid)
		local site = fname .. ":" .. tostring(nd.line)
		local schema = "non-nil"
		local c = claim.new({
			site = site,
			slot = "deref:" .. base_name,
			stratum = claim.STRATUM.PI1,
			modal = claim.MODAL.BOX,
			schema = schema,
			schema_key = schema,
			provenance = claim.PROVENANCE.MINED,
		})
		if c ~= nil then out[#out + 1] = c end
	end

	--: (integer, string) -> nil
	local function emit_branch_reachable(nid, which)
		local nd = nodes:get(nid)
		local site = fname .. ":" .. tostring(nd.line)
		local schema = "reachable"
		local c = claim.new({
			site = site,
			slot = "branch:" .. which,
			stratum = claim.STRATUM.SIGMA1,
			modal = claim.MODAL.DIAMOND,
			schema = schema,
			schema_key = schema,
			provenance = claim.PROVENANCE.MINED,
		})
		if c ~= nil then out[#out + 1] = c end
	end

	local walk -- forward, generic expression+statement walker

	--: (integer, integer) -> nil
	local function walk_list(start, len)
		for i = 0, len - 1 do
			walk(lists:get(start + i))
		end
	end

	--: (integer) -> nil
	walk = function(nid)
		if nid == 0 then return end
		local nd = nodes:get(nid)
		local k = nd.kind
		if k == defs.NODE_FIELD_EXPR then
			emit_deref(nid, nd.data[0])
			walk(nd.data[0])
		elseif k == defs.NODE_INDEX_EXPR then
			emit_deref(nid, nd.data[0])
			walk(nd.data[0])
			walk(nd.data[1])
		elseif k == defs.NODE_METHOD_CALL then
			emit_deref(nid, nd.data[0])
			walk(nd.data[0])
			walk_list(nd.data[2], nd.data[3])
		elseif k == defs.NODE_CALL_EXPR then
			walk(nd.data[0])
			walk_list(nd.data[1], nd.data[2])
		elseif k == defs.NODE_UNARY_EXPR then
			walk(nd.data[1])
		elseif k == defs.NODE_BINARY_EXPR then
			walk(nd.data[1])
			walk(nd.data[2])
		elseif k == defs.NODE_CAST_EXPR then
			walk(nd.data[0])
		elseif k == defs.NODE_TABLE_EXPR then
			walk_list(nd.data[0], nd.data[1])
		elseif k == defs.NODE_TABLE_FIELD then
			if nd.data[2] == defs.TFIELD_COMPUTED then walk(nd.data[0]) end
			walk(nd.data[1])
		elseif k == defs.NODE_FUNC_EXPR then
			walk_list(nd.data[2], nd.data[3])
		elseif k == defs.NODE_FUNC_DECL then
			walk_list(nd.data[3], nd.data[4])
		elseif k == defs.NODE_ASSIGN_STMT then
			walk_list(nd.data[0], nd.data[1])
			walk_list(nd.data[2], nd.data[3])
		elseif k == defs.NODE_LOCAL_STMT then
			walk_list(nd.data[2], nd.data[3])
		elseif k == defs.NODE_DO_STMT then
			walk_list(nd.data[0], nd.data[1])
		elseif k == defs.NODE_WHILE_STMT then
			walk(nd.data[0])
			walk_list(nd.data[1], nd.data[2])
		elseif k == defs.NODE_REPEAT_STMT then
			walk(nd.data[0])
			walk_list(nd.data[1], nd.data[2])
		elseif k == defs.NODE_IF_STMT then
			local cs, cl = nd.data[0], nd.data[1]
			for ci = 0, cl - 1 do
				local clid = lists:get(cs + ci)
				local cnd = nodes:get(clid)
				local which = ci == 0 and "then" or ("elseif:" .. tostring(ci))
				walk(cnd.data[0])
				emit_branch_reachable(clid, which)
				walk_list(cnd.data[1], cnd.data[2])
			end
			if band(nd.flags, defs.FLAG_HAS_ELSE) ~= 0 then
				emit_branch_reachable(nid, "else")
				walk_list(nd.data[2], nd.data[3])
			end
		elseif k == defs.NODE_FOR_NUM then
			walk(nd.data[1])
			walk(nd.data[2])
			if band(nd.flags, defs.FLAG_HAS_STEP) ~= 0 then walk(nd.data[3]) end
			walk_list(nd.data[4], nd.data[5])
		elseif k == defs.NODE_FOR_IN then
			walk_list(nd.data[2], nd.data[3])
			walk_list(nd.data[4], nd.data[5])
		elseif k == defs.NODE_RETURN_STMT then
			walk_list(nd.data[0], nd.data[1])
		elseif k == defs.NODE_EXPR_STMT then
			walk(nd.data[0])
		end
		-- Other kinds (NODE_LITERAL, NODE_IDENTIFIER, NODE_VARARG_EXPR,
		-- NODE_BREAK_STMT, NODE_GOTO_STMT, NODE_LABEL_STMT, NODE_CHUNK) have
		-- no children relevant to the two mined forms; fall through.
	end

	local root_nd = nodes:get(pr.root)
	walk_list(root_nd.data[0], root_nd.data[1])
	return out, nil
end

return M
