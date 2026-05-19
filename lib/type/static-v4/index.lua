-- Indexed access types — Phase 4b.2.
--
-- `T[K]` is a first-class lattice operation (rewrite design §1.1, §9.2.5). It
-- projects an "at-key K" value type out of a record-shaped type T. This module
-- implements `M.index(obj, key)` which eagerly *reduces* the operation to a
-- concrete v4 type when the lookup is decidable, and returns an error when it
-- is not.
--
-- Distribution rules (design §1.1):
--   T[K1 | K2]   = T[K1] | T[K2]               (union of keys distributes)
--   (R1 | R2)[K] = R1[K] | R2[K]               (union of records distributes)
--   (μX. body)[K] = body[K]                    (lazy unfold; relies on the
--                                               record's structural depth to
--                                               terminate — no cycle in K)
--
-- Reduction on the three record shapes:
--   * Closed `{ x: A, y: B }` with literal key "x"     → A
--   * Closed `{ x: A, y: B }` with literal key "z"     → ERROR (no such field)
--   * Open   `{ x: A, ... }`  with literal key "z"     → unknown (row variable
--                                                       contribution; proper
--                                                       row polymorphism is
--                                                       later)
--   * Indexer `{ [K']: V }`   with key K, K <: K'      → V
--   * Closed record with primitive key (e.g. T[string]) → union of all named
--                                                          field types
--
-- Deferred semantics (design §1.1 last paragraph): "Against an unbound
-- key-type-variable, indexed access becomes a deferred constraint." Phase 4a
-- does *not* yet expose a deferred-constraint queue (the solver has only the
-- single `<:` primitive plus eager variable bound propagation). Per CLAUDE.md
-- "Temporary measures are context poisoning" and "Ad-hoc conditions are
-- strictly forbidden", we do NOT bolt a one-off "pending index" queue on the
-- side for this single feature. Instead, when `index(obj, key)` cannot reduce
-- because either side mentions an unbound variable, we **reject loudly** with
-- an error explaining the missing mechanism. The full deferred-constraint
-- infrastructure lands later (alongside match-type suspension, which has the
-- same shape per design §5.3).
--
-- Negated keys: design §1.1 accepts them, but `~T` (complement) lands in
-- Phase 4c. 4b.2's lattice has no complement constructor, so negated keys
-- are *not constructible* in 4b.2. We do not pre-emptively reserve API
-- surface for them; when 4c lands, it adds complement first, then this module
-- gains a case for `key.tag == "neg"`.

local T = require("lib.type.static-v4.types")

local M = {}

-- ── Key analysis ─────────────────────────────────────────────────────────

-- Collect the set of string-literal keys a key type denotes, if all of its
-- value-domain inhabitants are string literals. Returns (literals, base) where
-- `literals` is an array of string values and `base` is either nil (only
-- literals) or "string" (the key is — or contains — the primitive `string`
-- itself, which selects ALL string-keyed fields of the target).
--
-- This recognizes exactly the shapes 4b.2 supports:
--   * a single literal:                  literal("string", "x")  → ({"x"}, nil)
--   * the string primitive:              prim("string")           → ({},    "string")
--   * a union of the above:               literal | literal | prim  → (...)
-- Anything else (variable, μ, function, record, intersection, top/bot, mixed
-- with non-string base) is rejected by returning nil + a reason.
--
-- We do NOT unfold variables to their bounds: a variable's bounds may tighten
-- after this call (that is the entire purpose of deferred resolution). Using
-- the *current* bounds would produce a result the solver would then have to
-- invalidate when new bounds arrive. The principled response is to refuse and
-- ask the caller to materialize the key first.
--: (V4Type) -> ({ [integer]: string } | nil, string | nil, string | nil)
local function analyze_key(k)
	local lits = {} --[[: { [integer]: string } ]]
	local base = nil --[[: string | nil ]]
	-- Walk a union flat: stack of pending key types. Bounded by the key's
	-- structural depth, which contains no cycles in 4b.2.
	local stack = { k } --[[: V4Type[] ]]
	local top = 1
	while top > 0 do
		local x = stack[top]
		top = top - 1
		if x == nil then break end -- defensive; stack is dense by construction
		if x.tag == "literal" then
			if x.base ~= "string" then
				return nil, nil, "indexed access key must be a string-typed key, got literal of base '" .. tostring(x.base) .. "'"
			end
			-- The V4Literal `value` is `unknown` because literals of different
			-- bases hold different Lua-runtime values (string vs number vs ...).
			-- We narrowed to `base == "string"` above, so the value is a string
			-- at runtime; assert it with a type guard so the checker sees it.
			local v = x.value
			if type(v) ~= "string" then
				return nil, nil, "indexed access key: malformed string literal (value is not a string)"
			end
			lits[#lits + 1] = v
		elseif x.tag == "prim" then
			if x.name ~= "string" then
				return nil, nil, "indexed access key must be string-typed, got primitive '" .. tostring(x.name) .. "'"
			end
			base = "string"
		elseif x.tag == "union" then
			for _, m in ipairs(x.members) do
				top = top + 1
				stack[top] = m
			end
		elseif x.tag == "var" then
			return nil, nil, "indexed access on an unbound type variable key is deferred until the variable is bound; Phase 4b.2 has no deferred-constraint queue (CLAUDE.md no-temporary-measures). Materialize the key first."
		else
			return nil, nil, "indexed access key must be a string literal, the string primitive, or a union thereof; got '" .. x.tag .. "'"
		end
	end
	return lits, base, nil
end

-- Dedup a list of v4 types by identity. Used to keep the union result tidy.
--: (V4Type[]) -> V4Type[]
local function dedup_by_identity(ts)
	local seen, out = {}, {} --[[: V4Type[] ]]
	for _, x in ipairs(ts) do
		if not seen[x] then
			seen[x] = true
			out[#out + 1] = x
		end
	end
	return out
end

-- Wrap a list of result types into the appropriate v4 type:
--   * 0 elements: bottom (never) — but we treat that case at the call site
--     and emit an error instead, because a *missing* lookup is almost always
--     a user bug (see header comment, "Reduction on the three record shapes").
--   * 1 element:  the element itself.
--   * N>1:        a union.
--: (V4Type[]) -> V4Type
local function from_members(ts)
	if #ts == 1 then return ts[1] end
	return T.union(ts)
end

-- ── Per-record-shape projection ──────────────────────────────────────────

local index -- forward decl

-- Project the indexed-access result of a single record `r` for a key analysis
-- result (lits, base). Returns (type, errmsg). Implements the per-shape rules
-- from the header comment.
--: (V4Type, { [integer]: string }, string | nil) -> (V4Type | nil, string | nil)
local function index_one_record(r, lits, base)
	-- Note: r.tag == "rec" is the caller's contract.
	local results = {} --[[: V4Type[] ]]
	-- Literal-key projection: each named-or-indexed lookup contributes one
	-- result.
	local ix = r.indexer
	for _, name in ipairs(lits) do
		local ft = r.fields[name]
		if ft ~= nil then
			results[#results + 1] = ft
		elseif ix ~= nil then
			-- The literal name must lie inside the indexer's key type. The
			-- indexer's key is typically a primitive (e.g. `string`); we use
			-- a *direct* check here (not the solver) because indexed access
			-- is a type-level operation and must not generate side effects on
			-- variables. If the indexer's key isn't a primitive we cannot
			-- discharge the obligation locally and we reject.
			local ik = ix.key
			if ik.tag == "prim" and ik.name == "string" then
				results[#results + 1] = ix.value
			elseif ik.tag == "literal" and ik.base == "string" and ik.value == name then
				results[#results + 1] = ix.value
			else
				return nil, "indexed access key \"" .. name .. "\" cannot be discharged against indexer key " .. T.show(ik)
			end
		elseif r.open then
			-- Open-row contribution: the row variable could carry any field.
			-- Without proper row polymorphism (later phase) the principled
			-- answer for "what type does this absent field have" on an open
			-- record is `unknown` — the user has not constrained it.
			results[#results + 1] = T.top()
		else
			-- Closed record + named-key miss: the lattice answer is `never`
			-- (no inhabitant has this field), but treating the user's typo
			-- as `never` silently degrades into confusing errors downstream.
			-- The principled response is to surface the bug at the indexed-
			-- access site itself.
			return nil, "indexed access: field \"" .. name .. "\" is not in closed record " .. T.show(r)
		end
	end
	-- Primitive (`string`) base: contributes the union of every value type the
	-- record can yield at a string-typed key.
	if base == "string" then
		for k in pairs(r.fields) do
			local v = r.fields[k]
			if v ~= nil then results[#results + 1] = v end
		end
		if ix ~= nil then
			local ik = ix.key
			-- For the indexer to contribute, `string <: indexer.key` must
			-- hold. Same local-check restriction as above.
			if ik.tag == "prim" and ik.name == "string" then
				results[#results + 1] = ix.value
			else
				return nil, "indexed access on a string-typed key against indexer key " .. T.show(ik) .. " is not decidable without the solver; reduce the key first"
			end
		elseif r.open then
			results[#results + 1] = T.top()
		end
		-- A closed record without indexer at the string primitive yields the
		-- union of all field types only — that's already accumulated.
	end
	if #results == 0 then
		-- Should be unreachable: every branch above either appends a result
		-- or returns an error. Guard for safety.
		return nil, "indexed access produced no result for " .. T.show(r)
	end
	return from_members(dedup_by_identity(results)), nil
end

-- ── Public entry point ───────────────────────────────────────────────────

-- Compute `obj[key]` as a v4 type. Returns (type, nil) on success or
-- (nil, errmsg) on failure. Failure modes:
--   * obj is not record-shaped (and is not a union of record-shaped types,
--     and is not a μ unfolding to one).
--   * key contains an unbound variable (deferred — see header).
--   * key denotes a literal not present in a closed record with no indexer.
--   * obj or key mentions a feature this phase cannot discharge locally
--     (e.g. an indexer with a key that needs the solver).
--
-- `M.index` is pure: it does NOT mutate `obj`, `key`, or any solver state.
-- Distribution over unions of records is applied recursively; μ types are
-- unfolded by reading `.body` (the cyclic Lua table already represents the
-- substituted form, same as in subtype.lua).
--: (V4Type, V4Type) -> (V4Type | nil, string | nil)
index = function(obj, key)
	-- Distribute over a union of objects.
	if obj.tag == "union" then
		local parts = {} --[[: V4Type[] ]]
		for _, m in ipairs(obj.members) do
			local r, err = index(m, key)
			if r == nil then return nil, err end
			parts[#parts + 1] = r --[[: V4Type]]
		end
		return from_members(dedup_by_identity(parts)), nil
	end
	-- Unfold μ. Termination: the *record* layer underneath μ is what we
	-- ultimately project from; the key is structurally finite (no μ allowed
	-- because key analysis only accepts string literals / primitives /
	-- unions). The single unfold therefore reaches a record in one step.
	if obj.tag == "mu" then
		return index(obj.body, key)
	end
	if obj.tag == "var" then
		return nil, "indexed access on a type variable target is deferred until the variable is bound; Phase 4b.2 has no deferred-constraint queue. Materialize the target first."
	end
	if obj.tag ~= "rec" then
		return nil, "indexed access target must be a record (or union/μ thereof); got '" .. obj.tag .. "'"
	end
	local lits, base, err = analyze_key(key)
	if lits == nil then return nil, err end
	return index_one_record(obj, lits, base)
end

M.index = index

return M
