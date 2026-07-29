-- lib/type/v10_cleanroom/term_algebra.lua
-- v10 kernel term algebra — REFERENCE TIER (cleanroom implementation).
--
-- Implements the ratified term-algebra spec from
-- docs/decisions/typechecker-v10-core-design.md plus the owner-adjudicated
-- rulings F1..F13 (adjudicated 2026-07-29; the design doc is being amended
-- to match — the rulings are authoritative over any transient doc state):
--   F1  binds[i+1] maps to de Bruijn index i (list-position order).
--   F2  subst is pure replacement (TAPL [k -> u]t) — indices > k are NOT
--       renumbered.
--   F3  subst with index k absent from t's free-variable context is a
--       no-op success, with no sort check.
--   F4  shift accepts negative amounts; underflow below the cutoff is a
--       data error (nil, errmsg). Inside match, underflow during the
--       non-linear depth adjustment is an ordinary match failure.
--   F5  match traversal is pre-order, left-to-right (normative); the
--       first occurrence in that order fixes the binding depth.
--   F6  all declaration name collisions reject (duplicate own sorts,
--       own-vs-import, import-vs-import); imported sorts are legal in
--       result position.
--   F7  a metavariable anywhere in the match SUBJECT is a data error,
--       distinct from no-match (see is_no_match).
--   F13 match checks the metavariable's sort at bind time; instantiate
--       rejects mis-sorted bindings; metavariable identity is the id
--       alone; the same id with two different sorts in one term is a
--       build-time error.
--
-- Reference tier ONLY: no interning, no lazy substitution, no fast paths.
-- Structural equality and eager substitution ARE the semantic definition.
--
-- Error convention: data errors return (nil, errmsg). A match failure
-- (no-match) also returns (nil, errmsg) but with the "no match: " prefix;
-- is_no_match distinguishes the two outcome kinds (F7 requires them
-- distinguishable).
--
-- Sort identity and operator identity are declared-object identity —
-- never name equality. Signatures and their contained declaration objects
-- are immutable after declaration (validity by construction).

local M = {}

--:: Sort = { name: string, signature: Signature }
--:: Signature = { name: string, version: integer, sorts: { [string]: Sort }, ops: { [string]: OpDecl } }
--:: OpArgDecl = { sort: Sort, binds: Sort[] }
--:: OpDecl = { name: string, result: Sort, args: OpArgDecl[], signature: Signature }
--:: TermArg = { bound_count: integer, term: Term }
--:: Term = { kind: "var" | "op" | "meta", sort: Sort, ctx: { [integer]: Sort }, metas: { [string]: Sort }, index?: integer, id?: string, decl?: OpDecl, args?: TermArg[] }
--:: Binding = { term: Term, depth: integer }
--:: Bindings = { [string]: Binding }
--:: ImportSpec = { from: Signature, sorts: string[] }
--:: OpArgSpec = { sort: string, binds?: string[] }
--:: OpSpec = { result: string, args: OpArgSpec[] }
--:: SignatureSpec = { name: string, version: integer, sorts: string[], imports?: ImportSpec[], ops: { [string]: OpSpec } }

-- ── shape predicates ──────────────────────────────────────────────────────────
-- TYPECHECKER WORKAROUND: runtime validation guards are expressed as named
-- predicates over `unknown` rather than inline `type(x)` checks. The natural
-- code would guard inline, but a direct `type(x) ~= "table"`-style guard on
-- an annotated parameter widens it to `unknown` for the rest of the function
-- instead of intersecting with the annotation (narrowing FROM `unknown`
-- works correctly; already-typed values degrade). Predicate helpers taking
-- `unknown` leave the caller's types intact. See TODO.md.

--: (v: unknown) -> boolean
local function is_table(v)
	return type(v) == "table"
end

--: (v: unknown) -> boolean
local function is_nonempty_string(v)
	return type(v) == "string" and v ~= ""
end

--: (v: unknown) -> boolean
local function is_integer(v)
	return type(v) == "number" and v == math.floor(v)
end

--- Structural term-shape predicate (auxiliary; identity-level validity is
--- guaranteed by construction through var/meta/build).
--: (v: unknown) -> boolean
M.is_term = function(v)
	if type(v) ~= "table" then return false end
	local k = v.kind
	return k == "var" or k == "op" or k == "meta"
end

local is_term = M.is_term

--: (v: unknown) -> boolean
local function is_sort(v)
	if type(v) ~= "table" then return false end
	return type(v.name) == "string" and type(v.signature) == "table"
end

--: (v: unknown) -> boolean
local function is_op_decl(v)
	if type(v) ~= "table" then return false end
	return type(v.name) == "string" and is_sort(v.result) and type(v.args) == "table"
end

-- ── immutability fence ────────────────────────────────────────────────────────
-- Declaration objects are immutable by contract: validation is complete at
-- declaration, and the kernel never mutates them. Runtime enforcement
-- boundary (Lua 5.1): __newindex traps only NEW keys, so adding fields
-- errors; writes to existing fields cannot be trapped without proxying,
-- which would break pairs/# iteration. Mutating a declaration field is
-- out-of-contract and unsupported.

local FROZEN_MT = {
	--: (t: unknown, k: unknown, v: unknown) -> nil
	__newindex = function(t, k, v)
		error("attempt to modify an immutable kernel declaration object", 2)
	end,
}

--: (t: unknown) -> nil
local function freeze(t)
	if type(t) == "table" then
		setmetatable(t, FROZEN_MT)
	end
end

-- ── signature declaration ─────────────────────────────────────────────────────

--- Declare an immutable signature: owned sorts, imported sorts, operators.
--- Validation happens entirely here; after success no malformed declaration
--- is observable. All name collisions reject (F6). Import citations resolve
--- against the source signature's sort namespace; failure to resolve rejects.
--: (spec: SignatureSpec) -> (Signature | nil, string | nil)
M.declare_signature = function(spec)
	if not is_table(spec) then return nil, "declare_signature: spec must be a table" end
	if not is_nonempty_string(spec.name) then
		return nil, "declare_signature: name must be a non-empty string"
	end
	if not is_integer(spec.version) then
		return nil, "declare_signature: version must be an integer"
	end
	if not is_table(spec.sorts) then
		return nil, "declare_signature: sorts must be a list of sort names"
	end
	if not is_table(spec.ops) then
		return nil, "declare_signature: ops must be a table of operator specs"
	end
	local sig = { name = spec.name, version = spec.version, sorts = {}, ops = {} }
	-- owned sorts
	for i = 1, #spec.sorts do
		local n = spec.sorts[i]
		if not is_nonempty_string(n) then
			return nil, "declare_signature: sort names must be non-empty strings"
		end
		if sig.sorts[n] ~= nil then
			return nil, ("declare_signature: duplicate sort name '%s'"):format(n)
		end
		local sort_obj = { name = n, signature = sig }
		freeze(sort_obj)
		sig.sorts[n] = sort_obj
	end
	-- imported sorts (identity preserved: the imported object IS the owner's object)
	local imports = spec.imports
	if imports ~= nil then
		if not is_table(imports) then
			return nil, "declare_signature: imports must be a list"
		end
		for i = 1, #imports do
			local imp = imports[i]
			if not is_table(imp) or not is_table(imp.from)
				or not is_table(imp.from.sorts) or not is_table(imp.sorts) then
				return nil, ("declare_signature: malformed import at index %d"):format(i)
			end
			for j = 1, #imp.sorts do
				local n = imp.sorts[j]
				if not is_nonempty_string(n) then
					return nil, "declare_signature: imported sort names must be non-empty strings"
				end
				local s = imp.from.sorts[n]
				if s == nil then
					return nil, ("declare_signature: unresolvable import — signature '%s' has no sort '%s'")
						:format(tostring(imp.from.name), n)
				end
				if sig.sorts[n] ~= nil then
					return nil, ("declare_signature: sort name collision on '%s'"):format(n)
				end
				sig.sorts[n] = s
			end
		end
	end
	-- operators
	for opname, opspec in pairs(spec.ops) do
		if not is_nonempty_string(opname) then
			return nil, "declare_signature: operator names must be non-empty strings"
		end
		if not is_table(opspec) then
			return nil, ("declare_signature: operator '%s' spec must be a table"):format(opname)
		end
		if not is_nonempty_string(opspec.result) then
			return nil, ("declare_signature: operator '%s' result must be a sort name"):format(opname)
		end
		local result = sig.sorts[opspec.result]
		if result == nil then
			return nil, ("declare_signature: operator '%s' result cites unknown sort '%s'")
				:format(opname, opspec.result)
		end
		if not is_table(opspec.args) then
			return nil, ("declare_signature: operator '%s' requires an args list (use {} for none)")
				:format(opname)
		end
		local adecls = {} --[[: OpArgDecl[] ]]
		for i = 1, #opspec.args do
			local a = opspec.args[i]
			if not is_table(a) or not is_nonempty_string(a.sort) then
				return nil, ("declare_signature: operator '%s' argument %d is malformed"):format(opname, i)
			end
			local asort = sig.sorts[a.sort]
			if asort == nil then
				return nil, ("declare_signature: operator '%s' argument %d cites unknown sort '%s'")
					:format(opname, i, a.sort)
			end
			local binds = {} --[[: Sort[] ]]
			local bspec = a.binds
			if bspec ~= nil then
				if not is_table(bspec) then
					return nil, ("declare_signature: operator '%s' argument %d has a malformed valence")
						:format(opname, i)
				end
				for j = 1, #bspec do
					local bn = bspec[j]
					if not is_nonempty_string(bn) then
						return nil, ("declare_signature: operator '%s' argument %d has a malformed valence")
							:format(opname, i)
					end
					local bsort = sig.sorts[bn]
					if bsort == nil then
						return nil, ("declare_signature: operator '%s' argument %d valence cites unknown sort '%s'")
							:format(opname, i, bn)
					end
					binds[j] = bsort
				end
			end
			local adecl = { sort = asort, binds = binds }
			freeze(binds)
			freeze(adecl)
			adecls[i] = adecl
		end
		local odecl = { name = opname, result = result, args = adecls, signature = sig }
		freeze(adecls)
		freeze(odecl)
		sig.ops[opname] = odecl
	end
	freeze(sig.sorts)
	freeze(sig.ops)
	freeze(sig)
	return sig
end

-- ── term constructors ─────────────────────────────────────────────────────────

--- Construct a variable node: de Bruijn index, intrinsically sorted.
--- Free-variable context cached at construction: { [index] = sort }.
--: (index: integer, sort: Sort) -> (Term | nil, string | nil)
M.var = function(index, sort)
	if not is_integer(index) or index < 0 then
		return nil, "var: index must be a non-negative integer"
	end
	if not is_sort(sort) then
		return nil, "var: sort must be a declared sort object"
	end
	return { kind = "var", sort = sort, ctx = { [index] = sort }, metas = {}, index = index }
end

--- Construct a metavariable node (legal in pattern positions only; the
--- replayer enforces groundness of concluded judgments). Metavariable
--- identity is the id alone (F13).
--: (id: string, sort: Sort) -> (Term | nil, string | nil)
M.meta = function(id, sort)
	if not is_nonempty_string(id) then
		return nil, "meta: id must be a non-empty string"
	end
	if not is_sort(sort) then
		return nil, "meta: sort must be a declared sort object"
	end
	return { kind = "meta", sort = sort, ctx = {}, metas = { [id] = sort }, id = id }
end

--- The ONLY way to construct an operator node. Checks arity, argument
--- sorts, valences (binder-sort context check, F1 index order), merges
--- free-variable contexts (same-index-same-sort) and metavariable
--- contexts (same-id-same-sort, F13). Ill-sorted terms are
--- unrepresentable, not detected. bound_count is stamped from the decl;
--- callers never supply it.
--: (decl: OpDecl, args: Term[]) -> (Term | nil, string | nil)
M.build = function(decl, args)
	if not is_op_decl(decl) then
		return nil, "build: decl is not an operator declaration"
	end
	if not is_table(args) then
		return nil, "build: args must be a list of terms"
	end
	local n_decl = #decl.args
	if #args ~= n_decl then
		return nil, ("build: operator '%s' expects %d argument(s), got %d")
			:format(decl.name, n_decl, #args)
	end
	local merged_ctx = {} --[[: { [integer]: Sort } ]]
	local merged_metas = {} --[[: { [string]: Sort } ]]
	local node_args = {} --[[: TermArg[] ]]
	for i = 1, n_decl do
		local ad = decl.args[i]
		local t = args[i]
		if not is_term(t) then
			return nil, ("build: argument %d is not a term"):format(i)
		end
		if t.sort ~= ad.sort then
			return nil, ("build: argument %d sort mismatch — expected '%s', got '%s'")
				:format(i, ad.sort.name, t.sort.name)
		end
		local n = #ad.binds
		for k, s in pairs(t.ctx) do
			if k < n then
				-- bound position: must match the declared binder sort (F1: binds[k+1] -> index k)
				if s ~= ad.binds[k + 1] then
					return nil, ("build: argument %d binder index %d sort mismatch — expected '%s', got '%s'")
						:format(i, k, ad.binds[k + 1].name, s.name)
				end
			else
				local mk = k - n
				local prev = merged_ctx[mk]
				if prev ~= nil and prev ~= s then
					return nil, ("build: free variable %d occurs with conflicting sorts across arguments")
						:format(mk)
				end
				merged_ctx[mk] = s
			end
		end
		for id, s in pairs(t.metas) do
			local prev = merged_metas[id]
			if prev ~= nil and prev ~= s then
				return nil, ("build: metavariable '%s' occurs with two different sorts"):format(id)
			end
			merged_metas[id] = s
		end
		node_args[i] = { bound_count = n, term = t }
	end
	return {
		kind = "op",
		sort = decl.result,
		ctx = merged_ctx,
		metas = merged_metas,
		decl = decl,
		args = node_args,
	}
end

-- ── the eight primitives (equal / shift / subst / match / instantiate /
--    is_ground / sort_of; build is above) ─────────────────────────────────────

--- Reference structural equality — the semantic definition. Sort,
--- operator, and metavariable comparisons are declared-object identity /
--- id equality; never name equality across signatures.
--: (a: Term, b: Term) -> boolean
M.equal = function(a, b)
	if a == b then return true end
	if a.kind ~= b.kind or a.sort ~= b.sort then return false end
	if a.kind == "var" then return a.index == b.index end
	if a.kind == "meta" then return a.id ~= nil and a.id == b.id end
	if a.decl ~= b.decl then return false end
	local aa, ba = a.args, b.args
	if aa == nil or ba == nil then return false end
	for i = 1, #aa do
		if not M.equal(aa[i].term, ba[i].term) then return false end
	end
	return true
end

local shift_rec
--: (t: Term, d: integer, cutoff: integer) -> (Term | nil, string | nil)
shift_rec = function(t, d, cutoff)
	if t.kind == "var" then
		local k = t.index
		if k == nil then return t end
		if k < cutoff then return t end
		local nk = k + d
		if nk < cutoff then
			return nil, ("shift: underflow — index %d shifted by %d falls below cutoff %d")
				:format(k, d, cutoff)
		end
		return M.var(nk, t.sort)
	elseif t.kind == "meta" then
		return t
	else
		local args = t.args
		local decl = t.decl
		if args == nil or decl == nil then return nil, "shift: malformed operator node" end
		local new_args = {} --[[: Term[] ]]
		for i = 1, #args do
			local a = args[i]
			local nt, err = shift_rec(a.term, d, cutoff + a.bound_count)
			if nt == nil then return nil, err end
			new_args[i] = nt
		end
		return M.build(decl, new_args)
	end
end

--- De Bruijn shift: indices >= cutoff move by d. d may be negative (F4);
--- an index that would fall below the cutoff is a data error.
--: (t: Term, d: integer, cutoff: integer) -> (Term | nil, string | nil)
M.shift = function(t, d, cutoff)
	if not is_term(t) then return nil, "shift: t is not a term" end
	if not is_integer(d) then return nil, "shift: amount must be an integer" end
	if not is_integer(cutoff) or cutoff < 0 then
		return nil, "shift: cutoff must be a non-negative integer"
	end
	return shift_rec(t, d, cutoff)
end

local subst_rec
--: (t: Term, k: integer, u: Term) -> (Term | nil, string | nil)
subst_rec = function(t, k, u)
	if t.ctx[k] == nil then return t end
	if t.kind == "var" then
		-- ctx[k] non-nil on a var node means index == k
		return u
	end
	-- metavariable nodes have an empty free-variable context: unreachable here
	local args = t.args
	local decl = t.decl
	if args == nil or decl == nil then return nil, "subst: malformed operator node" end
	local new_args = {} --[[: Term[] ]]
	for i = 1, #args do
		local a = args[i]
		local n = a.bound_count
		if a.term.ctx[k + n] == nil then
			new_args[i] = a.term
		else
			local su, serr = shift_rec(u, n, 0)
			if su == nil then return nil, serr end
			local nt, err = subst_rec(a.term, k + n, su)
			if nt == nil then return nil, err end
			new_args[i] = nt
		end
	end
	return M.build(decl, new_args)
end

--- Eager capture-avoiding substitution of u for free variable k — the
--- reference semantics. Pure replacement: indices > k are NOT renumbered
--- (F2). If k is not free in t the call is a no-op success with no sort
--- check (F3); otherwise sort_of(u) must equal the target variable's
--- sort (sort-safety).
--: (t: Term, k: integer, u: Term) -> (Term | nil, string | nil)
M.subst = function(t, k, u)
	if not is_term(t) then return nil, "subst: t is not a term" end
	if not is_integer(k) or k < 0 then
		return nil, "subst: index must be a non-negative integer"
	end
	if not is_term(u) then return nil, "subst: replacement is not a term" end
	local target = t.ctx[k]
	if target == nil then return t end
	if u.sort ~= target then
		return nil, ("subst: sort mismatch — variable %d has sort '%s', replacement has sort '%s'")
			:format(k, target.name, u.sort.name)
	end
	return subst_rec(t, k, u)
end

local NO_MATCH_PREFIX = "no match: "

--- True when errmsg (from match / match_into) denotes an ordinary match
--- failure rather than a data error (F7 distinction).
--: (errmsg: string) -> boolean
M.is_no_match = function(errmsg)
	return errmsg:sub(1, #NO_MATCH_PREFIX) == NO_MATCH_PREFIX
end

local match_rec
--: (p: Term, t: Term, depth: integer, bindings: Bindings) -> (boolean | nil, string | nil)
match_rec = function(p, t, depth, bindings)
	if p.kind == "meta" then
		local id = p.id
		if id == nil then return nil, "match: malformed metavariable node" end
		if t.sort ~= p.sort then
			return nil, NO_MATCH_PREFIX
				.. ("metavariable '%s' of sort '%s' cannot match a term of sort '%s'")
					:format(id, p.sort.name, t.sort.name)
		end
		local existing = bindings[id]
		if existing == nil then
			bindings[id] = { term = t, depth = depth }
			return true
		end
		-- non-linear recurrence: shift-adjust across binder depths, then
		-- check with structural equality (bind-time equality, ratified)
		local shifted = shift_rec(existing.term, depth - existing.depth, 0)
		if shifted == nil then
			-- F4: underflow during depth adjustment = ordinary match failure
			return nil, NO_MATCH_PREFIX
				.. ("metavariable '%s' recurrence at depth %d has no consistent binding")
					:format(id, depth)
		end
		if not M.equal(t, shifted) then
			return nil, NO_MATCH_PREFIX
				.. ("metavariable '%s' bound to two different terms"):format(id)
		end
		return true
	elseif p.kind == "var" then
		if t.kind == "var" and t.index == p.index and t.sort == p.sort then return true end
		return nil, NO_MATCH_PREFIX .. "variable mismatch"
	else
		if t.kind ~= "op" or t.decl ~= p.decl then
			return nil, NO_MATCH_PREFIX .. "operator mismatch"
		end
		local pa = p.args
		local ta = t.args
		if pa == nil or ta == nil then return nil, "match: malformed operator node" end
		for i = 1, #pa do
			local ok, err = match_rec(pa[i].term, ta[i].term, depth + pa[i].bound_count, bindings)
			if not ok then return nil, err end
		end
		return true
	end
end

--- Match pattern against term, accumulating into an existing bindings
--- environment (the shared-environment entry point the replayer's
--- premise matching requires). Traversal is pre-order, left-to-right
--- (F5, normative). On failure the environment may retain partial
--- bindings; callers must discard it. Subject terms containing
--- metavariables are a data error (F7), distinct from no-match.
--: (pattern: Term, term: Term, bindings: Bindings) -> (boolean | nil, string | nil)
M.match_into = function(pattern, term, bindings)
	if not is_term(pattern) then return nil, "match: pattern is not a term" end
	if not is_term(term) then return nil, "match: subject is not a term" end
	if not is_table(bindings) then return nil, "match: bindings must be a table" end
	if next(term.metas) ~= nil then
		return nil, "match: subject term contains a metavariable"
	end
	return match_rec(pattern, term, 0, bindings)
end

--- First-order, deterministic matching; no search. Non-linear patterns
--- allowed: first occurrence (pre-order, left-to-right) binds; later
--- occurrences are checked via shift-adjusted structural equality.
--- Returns a fresh bindings environment: { [meta id] = { term, depth } }.
--: (pattern: Term, term: Term) -> (Bindings | nil, string | nil)
M.match = function(pattern, term)
	local bindings = {} --[[: Bindings ]]
	local ok, err = M.match_into(pattern, term, bindings)
	if not ok then return nil, err end
	return bindings
end

local inst_rec
--: (p: Term, depth: integer, bindings: Bindings) -> (Term | nil, string | nil)
inst_rec = function(p, depth, bindings)
	if p.kind == "meta" then
		local id = p.id
		if id == nil then return nil, "instantiate: malformed metavariable node" end
		local b = bindings[id]
		if b == nil then
			return nil, ("instantiate: unbound metavariable '%s'"):format(id)
		end
		if not is_table(b) or not is_term(b.term) or not is_integer(b.depth) then
			return nil, ("instantiate: malformed binding for metavariable '%s'"):format(id)
		end
		if b.term.sort ~= p.sort then
			return nil, ("instantiate: metavariable '%s' has sort '%s' but its binding has sort '%s'")
				:format(id, p.sort.name, b.term.sort.name)
		end
		return shift_rec(b.term, depth - b.depth, 0)
	elseif p.kind == "var" then
		return p
	else
		local args = p.args
		local decl = p.decl
		if args == nil or decl == nil then return nil, "instantiate: malformed operator node" end
		local new_args = {} --[[: Term[] ]]
		for i = 1, #args do
			local a = args[i]
			local nt, err = inst_rec(a.term, depth + a.bound_count, bindings)
			if nt == nil then return nil, err end
			new_args[i] = nt
		end
		return M.build(decl, new_args)
	end
end

--- Apply a bindings environment to a pattern, shifting each binding by
--- (occurrence depth - binding depth); exact inverse of match. Unbound
--- metavariables and mis-sorted bindings (F13) are errors; a shift
--- underflow (occurrence shallower than the binding permits) is a data
--- error.
--: (pattern: Term, bindings: Bindings) -> (Term | nil, string | nil)
M.instantiate = function(pattern, bindings)
	if not is_term(pattern) then return nil, "instantiate: pattern is not a term" end
	if not is_table(bindings) then return nil, "instantiate: bindings must be a table" end
	return inst_rec(pattern, 0, bindings)
end

--- True when t contains no metavariable nodes (O(1): metavariable
--- context cached at build).
--: (t: Term) -> boolean
M.is_ground = function(t)
	return next(t.metas) == nil
end

--- True when t has no free variables (O(1): free-variable context cached
--- at build). Auxiliary accessor over the ratified per-node cache.
--: (t: Term) -> boolean
M.is_closed = function(t)
	return next(t.ctx) == nil
end

--- O(1): sort stored at build.
--: (t: Term) -> Sort
M.sort_of = function(t)
	return t.sort
end

return M
