-- lib/type/v10_kernel/term_algebra/shared.lua
--
-- Tier-independent structural utilities for the v10 kernel term algebra:
-- signature/operator declaration validation, and the free-variable-context
-- bookkeeping used by every term-construction path in both tiers.
--
-- This is deliberately NOT one of the tiered primitives (build/equal/shift/
-- subst/match/instantiate/is_ground/sort_of are what the reference and fast
-- tiers implement independently, per docs/decisions/typechecker-v10-core-design.md).
-- Context-merge arithmetic is registry/grammar-side data manipulation shared
-- by both tiers' `build`, not an algorithm the tiers differ on.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: SortName = string
--:: SortDecl = { name: string, sig_name: string, sig_version: integer }
--:: Ctx = { [integer]: SortDecl }
--:: OpArgDecl = { sort: SortDecl, binds: SortDecl[], bound_count: integer }
--:: OpDecl = { name: string, sig_name: string, sig_version: integer, result: SortDecl, args: OpArgDecl[], arity: integer }
--:: Signature = { name: string, version: integer, sorts: { [string]: SortDecl }, sort_set: { [unknown]: boolean }, ops: { [string]: OpDecl } }

--:: OpArgSpec = { sort: SortName, binds: SortName[] | nil }
--:: OpSpec = { result: SortName, args: OpArgSpec[] | nil }
--:: SignatureSpec = { name: string, version: integer, sorts: SortName[], ops: { [string]: OpSpec }, imports: { [string]: SortDecl } | nil }

-- ── Sort identity ────────────────────────────────────────────────────────────
--
-- Sorts are identity-carrying declared objects (owning signature name +
-- version + display name), never bare strings — the same principle already
-- ratified for operators, extended to sorts (docs/decisions/typechecker-v10-
-- core-design.md, "Sort identity: identity-by-declaration + explicit
-- imports"; this closes the gap recorded in docs/typechecker-v10-pilot-
-- signatures-proposal.md §4 — option C of the three recorded there).
-- `declare_signature`'s `spec.sorts` declares sorts OWNED by this signature
-- (fresh SortDecl objects minted here); `spec.imports` cites SortDecl objects
-- already owned by another, previously-declared signature (the exact same
-- table reference is reused under a local name — never copied — so identity
-- survives the citation). Every downstream sort comparison (build's arg/
-- binder-sort checks, equal/match/instantiate's var/meta sort checks, in
-- both tiers) is therefore Lua object identity (`==`/`~=` on the SortDecl
-- table), never name equality — a sort literally named the same in two
-- independently-declared signatures is two different objects and does not
-- compare equal.

--: (v: unknown) -> boolean
function M.is_sort_decl(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown } ]]
	return type(t.name) == "string" and type(t.sig_name) == "string" and type(t.sig_version) == "number"
end

-- ── Signature declaration ────────────────────────────────────────────────────
--
-- Validates EVERYTHING once: unknown sorts, unresolvable imports, malformed
-- valences. After this returns a signature, no later call can observe a
-- malformed decl — decl objects are the interned, immutable operator/sort
-- identities (operator identity = declared-object identity; two signatures
-- declaring the same-named op declare different operators — sorts now carry
-- the same guarantee).

-- `spec` is genuinely external/untrusted data (that is the entire point of
-- validating it), so it is typed `unknown` per convention — narrowed by hand
-- via checked casts (`--[[: T]]`) only after each field's shape is verified
-- at runtime, never assumed.
--: (spec: unknown) -> (Signature | nil, string | nil)
function M.declare_signature(spec)
	if type(spec) ~= "table" then return nil, "declare_signature: spec must be a table" end
	local spec_t = spec --[[: { [string]: unknown } ]]

	local name = spec_t.name
	if type(name) ~= "string" then return nil, "declare_signature: spec.name must be a string" end

	local version_raw = spec_t.version
	if type(version_raw) ~= "number" then return nil, "declare_signature: spec.version must be an integer" end
	if version_raw ~= math.floor(version_raw) then
		return nil, "declare_signature: spec.version must be an integer"
	end
	local version = math.floor(version_raw)

	local sorts_spec = spec_t.sorts
	if type(sorts_spec) ~= "table" then return nil, "declare_signature: spec.sorts must be an array" end

	local sorts = {} --[[: { [string]: SortDecl } ]]
	local sort_set = {} --[[: { [unknown]: boolean } ]]
	for _, s in ipairs(sorts_spec) do
		if type(s) ~= "string" then return nil, "declare_signature: sort names must be strings" end
		if sorts[s] then return nil, "declare_signature: duplicate sort " .. s end
		local sortdecl = { name = s, sig_name = name, sig_version = version }
		sorts[s] = sortdecl
		sort_set[sortdecl --[[: unknown ]]] = true
	end

	-- Imports: cite SortDecl objects already owned by another, previously-
	-- declared signature under a local name usable in THIS signature's op
	-- specs, exactly like a locally-declared sort. Rejected (never a runtime
	-- surprise later): a local name colliding with spec.sorts or another
	-- import, or a value that is not a well-formed SortDecl object (shape-
	-- checked via is_sort_decl — the same level of validation build_var/
	-- build_meta apply to a caller-supplied sort, since there is no global
	-- signature registry to check liveness against beyond structural shape).
	local imports_spec = spec_t.imports or {}
	if type(imports_spec) ~= "table" then return nil, "declare_signature: spec.imports must be a table" end
	local imports = imports_spec --[[: { [unknown]: unknown } ]]
	for localname_raw, sortdecl_raw in pairs(imports) do
		if type(localname_raw) ~= "string" then
			return nil, "declare_signature: import names must be strings"
		end
		local localname = localname_raw
		if sorts[localname] then
			return nil, "declare_signature: import " .. localname .. " collides with a locally-declared sort"
		end
		if type(sortdecl_raw) ~= "table" then
			return nil, "declare_signature: import " .. localname .. " is not a declared sort object"
		end
		local sd_check = sortdecl_raw --[[: { [string]: unknown } ]]
		if type(sd_check.name) ~= "string" or type(sd_check.sig_name) ~= "string" or type(sd_check.sig_version) ~= "number" then
			return nil, "declare_signature: import " .. localname .. " is not a declared sort object"
		end
		-- Type-only narrowing (same pattern as term_algebra_parity_test.lua's
		-- `as_decl`): casts the SAME table reference `sd_check` aliases,
		-- never copies it — import identity depends on this being the exact
		-- object the source signature owns, not a reconstruction.
		local sortdecl = sortdecl_raw --[[: SortDecl ]]
		sorts[localname] = sortdecl
		sort_set[sortdecl --[[: unknown ]]] = true
	end

	local ops_spec = spec_t.ops
	if type(ops_spec) ~= "table" then return nil, "declare_signature: spec.ops must be a table" end

	local ops = {} --[[: { [string]: OpDecl } ]]
	for opname, opspec_ in pairs(ops_spec) do
		if type(opname) ~= "string" then return nil, "declare_signature: operator names must be strings" end
		if type(opspec_) ~= "table" then return nil, "declare_signature: malformed operator spec for " .. opname end
		local opspec = opspec_ --[[: { [string]: unknown } ]]

		local result = opspec.result
		if type(result) ~= "string" or not sorts[result] then
			return nil, "declare_signature: operator " .. opname .. " has unknown result sort"
		end

		local argspecs = opspec.args or {}
		if type(argspecs) ~= "table" then
			return nil, "declare_signature: operator " .. opname .. " has malformed args"
		end

		local args = {} --[[: OpArgDecl[] ]]
		-- TYPECHECKER WORKAROUND: the natural code is `for i, argspec_ in
		-- ipairs(argspecs) do` using the ipairs-supplied index directly for
		-- both `args[i]` and the diagnostic messages below. When `argspecs`
		-- is narrowed from an index-signature-typed `unknown` field (via
		-- `type(x) == "table"`) rather than declared as `unknown[]` outright,
		-- the typechecker infers the ipairs index variable as `never` (see
		-- TODO.md). Worked around with an explicit counter.
		local i = 0
		for _, argspec_ in ipairs(argspecs) do
			i = i + 1
			if type(argspec_) ~= "table" then
				return nil, "declare_signature: operator " .. opname .. " arg " .. i .. " has unknown sort"
			end
			local argspec = argspec_ --[[: { [string]: unknown } ]]
			local argsort = argspec.sort
			if type(argsort) ~= "string" or not sorts[argsort] then
				return nil, "declare_signature: operator " .. opname .. " arg " .. i .. " has unknown sort"
			end

			local binds_spec = argspec.binds or {}
			if type(binds_spec) ~= "table" then
				return nil, "declare_signature: operator " .. opname .. " arg " .. i .. " has malformed binds"
			end

			local binds = {} --[[: SortDecl[] ]]
			local j = 0
			for _, bsort in ipairs(binds_spec) do
				j = j + 1
				if type(bsort) ~= "string" or not sorts[bsort] then
					return nil, "declare_signature: operator " .. opname .. " arg " .. i
						.. " binds " .. j .. " has unknown sort"
				end
				binds[j] = sorts[bsort]
			end
			args[i] = { sort = sorts[argsort], binds = binds, bound_count = #binds }
		end
		ops[opname] = {
			name = opname,
			sig_name = name,
			sig_version = version,
			result = sorts[result],
			args = args,
			arity = #args,
		}
	end

	return { name = name, version = version, sorts = sorts, sort_set = sort_set, ops = ops }
end

-- ── Context bookkeeping ──────────────────────────────────────────────────────
--
-- ctx(t): map from every de Bruijn index free in t (relative to t's own
-- root) to its sort. var(k,s) has ctx = {[k]=s}; meta has ctx = {} (a
-- metavariable is a distinguished leaf, not a bound-variable reference);
-- op's ctx is computed bottom-up per argument (see discharge_arg_ctx) then
-- merged across arguments (see merge_ctxs). Ratified construction: for an
-- argument with declared binds = {s1..sn}, indices 0..n-1 in that argument's
-- own context must match s1..sn positionally where present (unreferenced
-- binders are fine); those entries are discharged (removed — they refer to
-- binders this argument itself introduces) and the remaining indices shift
-- down by n (to re-express them relative to the enclosing op node's scope).

-- Validate + discharge one argument's context against its declared valence.
--: (ctx: Ctx, binds: SortDecl[]) -> (Ctx | nil, string | nil)
function M.discharge_arg_ctx(ctx, binds)
	local n = #binds
	for idx = 0, n - 1 do
		local s = ctx[idx]
		if s ~= nil and s ~= binds[idx + 1] then
			return nil, "bound variable " .. idx .. " expected sort " .. binds[idx + 1].name .. ", got " .. s.name
		end
	end
	local outer = {} --[[: Ctx ]]
	for idx, s in pairs(ctx) do
		if idx >= n then outer[idx - n] = s end
	end
	return outer
end

-- Merge already-discharged per-argument contexts into one node context.
-- Conflicting sorts for the same index across arguments is ill-formed.
--: (ctxs: Ctx[]) -> (Ctx | nil, string | nil)
function M.merge_ctxs(ctxs)
	local merged = {} --[[: Ctx ]]
	for _, ctx in ipairs(ctxs) do
		for idx, s in pairs(ctx) do
			if merged[idx] ~= nil and merged[idx] ~= s then
				return nil, "context merge conflict at index " .. idx
			end
			merged[idx] = s
		end
	end
	return merged
end

return M
