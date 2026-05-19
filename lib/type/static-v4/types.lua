-- Type representation for the v4 typechecker foundation.
--
-- Following the rewrite design (docs/typechecker-rewrite-design.md §4.1), a
-- "simple type" is one of: a primitive token, a literal, a constructor
-- application, a type variable carrying mutable lower/upper bound lists, or a
-- boolean combination (union/intersection). Phase 4a does not include
-- complement, recursion, or quantifiers — those land in later phases.
--
-- Every type is a table with a `tag` field discriminating its shape. The
-- remaining fields are tag-specific and present at construction (see CLAUDE.md
-- "Table construction" — all shape-defining fields go in the literal so the
-- JIT sees one hidden class per tag).

local M = {}

-- Type representation. Every v4 type is a tagged record; the union below is
-- the discriminated union of every possible shape. Internal code MUST branch
-- on the `tag` field before reading other fields; the typechecker narrows the
-- union on a `tag == "..."` comparison.
--
-- Note: V4Var.lower_vars / upper_vars are sets — { [V4Type]: boolean } — but
-- the Lua annotation syntax doesn't allow non-string-or-integer index keys on
-- index signatures, so we annotate them as a sparse map from var id to the
-- var. Code accesses them as sets and we cast the value via the discriminant
-- when iterating.
--:: V4Top     = { tag: "top" }
--:: V4Bot     = { tag: "bot" }
--:: V4Prim    = { tag: "prim", name: string }
--:: V4Literal = { tag: "literal", base: string, value: unknown }
--:: V4Fn      = { tag: "fn", params: V4Type[], ret: V4Type }
--:: V4Indexer = { key: V4Type, value: V4Type }
--:: V4Rec     = { tag: "rec", fields: { [string]: V4Type }, open: boolean, indexer: V4Indexer | nil }
--:: V4Union   = { tag: "union", members: V4Type[] }
--:: V4Inter   = { tag: "inter", members: V4Type[] }
--:: V4Var     = { tag: "var", id: integer, name: string, lower: V4Type[], upper: V4Type[], lower_vars: { [integer]: V4Type }, upper_vars: { [integer]: V4Type } }
--:: V4Mu      = { tag: "mu", id: integer, body: V4Type }
--:: V4Neg     = { tag: "neg", body: V4Type }
--:: V4Forall  = { tag: "forall", vars: V4Type[], body: V4Type }
--:: V4Skolem  = { tag: "skolem", id: integer, name: string }
--:: V4Type    = V4Top | V4Bot | V4Prim | V4Literal | V4Fn | V4Rec | V4Union | V4Inter | V4Var | V4Mu | V4Neg | V4Forall | V4Skolem

-- Working types used by empty.lua. Declared here because cross-file `--::`
-- aliases referencing V4Type don't currently resolve through transitive
-- requires — keeping the DNF shape next to V4Type itself sidesteps that.
--:: DnfDisjunct = { pos: V4Type[], neg: V4Type[] }
--:: Dnf         = { [integer]: DnfDisjunct }

-- Working type used by match.lua. Same cross-file-alias workaround: declared
-- here so V4Arm's V4Type references resolve. A match arm is a pattern, a
-- result template, and the list of capture variables shared between them.
-- The arm's wildcard sibling is NOT represented here — wildcards are passed
-- as a side `wildcard_result` argument to the match API because their
-- pattern is synthesized from the union of the other arms.
--:: V4Arm = { pattern: V4Type, result: V4Type, captures: V4Type[] }

-- ── Tags ──────────────────────────────────────────────────────────────────

-- Tag string constants are exposed for callers wanting to switch on tag.
-- Inside this module we use the string literals directly (not these
-- aliases) because the typechecker narrows the V4Type union on
-- `t.tag == "prim"` comparisons but not on `t.tag == M.TAG_PRIM`
-- (which is typed `string`, not the singleton literal type).

-- Top-level lattice elements.
M.TAG_TOP       = "top"
M.TAG_BOT       = "bot"

-- Primitive types. Distinguished from literal types: `42` (literal) <: integer
-- <: number; `"GET"` <: string. The primitive name is stored verbatim.
M.TAG_PRIM      = "prim"
M.TAG_LITERAL   = "literal"

-- Compound constructors.
M.TAG_FN        = "fn"
M.TAG_REC       = "rec"

-- Boolean combinators.
M.TAG_UNION     = "union"
M.TAG_INTER     = "inter"

-- Equi-recursive type. The `body` typically contains a reference back to the
-- enclosing `mu` table (a cyclic Lua structure), expressing `μX. body[X]`.
-- Subtyping unfolds one step on demand and relies on the solver's cache to
-- terminate when the same (mu, other) pair recurs (Amadio-Cardelli 1993; see
-- MLstruct §3.2 for the cache discipline shared with cyclic variable bounds).
-- We give each `mu` a unique id for deterministic display naming.
M.TAG_MU        = "mu"

-- Complement / negation. `body` is the type being complemented. Boolean
-- combinator alongside union and intersection; `~T` denotes the set of all
-- runtime values not in T (rewrite design §1.2). Involutive (`~~T = T`),
-- De Morgan dualizes ∨/∧, `~⊥ = ⊤` and `~⊤ = ⊥`. The constructor performs
-- these three short-circuits at construction time; the simplifier in
-- subtype.lua / empty.lua applies the rest of the boolean-algebra laws on
-- demand (De Morgan push-down, distribution, self-cancellation `T ∩ ¬T = ⊥`).
M.TAG_NEG       = "neg"

-- Universal quantification `∀X1...Xn. body`. The `vars` list holds the bound
-- type-variable placeholders (V4Var nodes used as templates — never solved
-- against directly; they are substituted out at instantiate/skolemize time).
-- See rank-N polymorphism, design §6: Peyton-Jones et al. 2007 deep-
-- skolemization at subsumption. Foralls are first-class types and can appear
-- inside other constructors (function params for higher-rank).
M.TAG_FORALL    = "forall"

-- Skolem constants: opaque rigid nominal tags introduced when subsumption
-- skolemizes the RHS of `T <: ∀X. U`. MLstruct §3.4's `#F` flexible nominal
-- tags. Each skolem is a distinct atomic constructor in the lattice; subtype
-- holds only by reflexivity (skolem <: itself, skolem <: top, bot <: skolem).
-- Two distinct skolems are not <: each other but also not provably disjoint
-- (they "coexist" — their intersection is not ⊥ per the paper).
M.TAG_SKOLEM    = "skolem"

-- Inference variable. lower/upper bounds accumulate during constraint solving.
-- Per simple-sub (Parreaux 2020) / MLstruct §3.2: each variable carries a
-- list of non-variable lower bounds and non-variable upper bounds plus a list
-- of variables it is linked to. We do not store the "level" used for
-- generalization — generalization is a later phase concern; 4a only solves
-- subtyping constraints on a single level.
M.TAG_VAR       = "var"

-- ── Primitive lattice ─────────────────────────────────────────────────────
-- Hardcoded subtype edges between primitives. Per type-system.md "Primitives":
-- integer <: number. All other primitives are pairwise unrelated.
--
-- A nil-literal value (e.g. the only inhabitant of the type `nil`) is modelled
-- as the `nil` primitive; there is no separate "nil literal".
local PRIM_SUB = {
	-- subtype = { supertype1 = true, supertype2 = true, ... }
	-- Reflexivity is implicit (handled by the algorithm).
	integer = { number = true },
}

-- Public predicate: does `sub` <: `sup` hold at the primitive level?
--: (string, string) -> boolean
function M.prim_subtype(sub, sup)
	if sub == sup then return true end
	local sups = PRIM_SUB[sub]
	if sups == nil then return false end
	return sups[sup] == true
end

-- Known primitive names. A value not in this set is rejected at construction.
local KNOWN_PRIMS = {
	["nil"] = true, boolean = true, number = true, integer = true,
	string = true, cdata = true,
}

-- ── Constructors ──────────────────────────────────────────────────────────

local TOP = { tag = M.TAG_TOP }
local BOT = { tag = M.TAG_BOT }

function M.top() return TOP end
function M.bot() return BOT end

--: (string) -> V4Type
function M.prim(name)
	if not KNOWN_PRIMS[name] then
		error("unknown primitive: " .. tostring(name), 2)
	end
	return { tag = M.TAG_PRIM, name = name }
end

-- Literal type. `value` is the Lua value; `base` is the primitive name it
-- belongs to. We don't infer the base from the value to keep the constructor
-- explicit (and to allow `integer` vs `number` distinction on numeric values).
--: (string, unknown) -> V4Type
function M.literal(base, value)
	if not KNOWN_PRIMS[base] then
		error("unknown literal base: " .. tostring(base), 2)
	end
	return { tag = M.TAG_LITERAL, base = base, value = value }
end

-- Function type. params is a list of types; ret is a single type. Multi-return
-- is represented as ret being a tuple (record with positional keys) — out of
-- scope for 4a as a tested feature, but the representation does not preclude
-- it.
--: (V4Type[], V4Type) -> V4Type
function M.fn(params, ret)
	return { tag = M.TAG_FN, params = params, ret = ret }
end

-- Record type. `fields` is a name → type map. `open` true means an open row
-- (extra fields permitted); false means closed (exact field set). This is the
-- structural-subtyping width control. `indexer`, if non-nil, is the
-- `{ [K]: V }` index signature — any key of type `K` (additionally to the
-- named fields, if any) maps to `V`. An indexer-typed record is necessarily
-- "open" in the sense of width, but `open` (the row-extension flag) and
-- `indexer` (a typed index signature) are *distinct* per the type-system
-- reference: `{ name: string, ... }` is open with no indexer (excess fields
-- have type `unknown`), `{ [string]: integer }` has an indexer and no named
-- fields, and the two can be combined.
--: ({ [string]: V4Type }, boolean, V4Indexer | nil) -> V4Type
function M.rec(fields, open, indexer)
	if open == nil then open = false end
	return { tag = M.TAG_REC, fields = fields, open = open, indexer = indexer }
end

-- Indexer constructor. Sugar for `{ key = k, value = v }`.
--: (V4Type, V4Type) -> V4Indexer
function M.indexer(k, v) return { key = k, value = v } end

-- Union and intersection. Members list is preserved verbatim; flattening and
-- absorption are done by the simplifier in subtype.lua when needed for
-- decomposition. Building `union({A})` returns a 1-element union — the caller
-- may want a single type back, but we don't flatten at construction because
-- the constraint solver may build intermediate forms.
--: (V4Type[]) -> V4Type
function M.union(members) return { tag = M.TAG_UNION, members = members } end
--: (V4Type[]) -> V4Type
function M.inter(members) return { tag = M.TAG_INTER, members = members } end

-- Fresh type variable. Each variable gets a unique numeric id for cache keys
-- and a human-readable name for diagnostics.
local _next_var_id = 0
--: (string | nil) -> V4Type
function M.var(name)
	_next_var_id = _next_var_id + 1
	return {
		tag        = M.TAG_VAR,
		id         = _next_var_id,
		name       = name or ("α" .. _next_var_id),
		-- Non-variable bounds. Lists; the union of lowers is the variable's
		-- inferred floor, the intersection of uppers is its ceiling.
		lower      = {},
		upper      = {},
		-- Variable-to-variable links, keyed by var id (a map id → var). The
		-- solver propagates bounds across these links to maintain transitive
		-- closure. lower_vars[v.id] = v means v <: self; upper_vars[v.id] = v
		-- means self <: v.
		lower_vars = {},
		upper_vars = {},
	}
end

-- Reset the id counter. Tests may want deterministic ids; we don't make this
-- automatic because some tests interleave fresh-var creation across cases.
function M._reset_var_ids() _next_var_id = 0 end

-- Equi-recursive type. The user-facing constructor is `fix`: it takes a
-- function that, given a self-reference handle, returns the body. The handle
-- IS the `mu` node — so any occurrence of `self` inside `body` shares the
-- same Lua table, producing a cyclic structure. Termination during subtyping
-- relies on the solver's identity-keyed cache (subtype.lua): the same
-- (mu, other) pair encountered a second time is admitted as proved.
--
-- The body is filled in after construction (two-step build) so the closure
-- can refer to the mu node. CLAUDE.md's "all shape-defining fields in the
-- literal" rule still applies — `body` is present at construction, just
-- initially set to a placeholder that we overwrite immediately. We do not
-- expose the mu node before the body is set.
local _next_mu_id = 0
--: ((V4Type) -> V4Type) -> V4Type
function M.fix(f)
	_next_mu_id = _next_mu_id + 1
	local node = {
		tag  = M.TAG_MU,
		id   = _next_mu_id,
		body = TOP --[[: V4Type]], -- placeholder; overwritten before the function returns
	}
	node.body = f(node)
	return node
end

-- Direct `mu` constructor for callers that already have a body referring to
-- the node by table identity (e.g. test fixtures that built the cycle
-- manually). Prefer `fix` — this exists for parity with the type union.
--: (V4Type) -> V4Type
function M.mu(body)
	_next_mu_id = _next_mu_id + 1
	return { tag = M.TAG_MU, id = _next_mu_id, body = body }
end

function M._reset_mu_ids() _next_mu_id = 0 end

-- Complement constructor. Three short-circuits per design §1.2:
--   ~⊤ = ⊥, ~⊥ = ⊤, ~~T = T.
-- No further simplification (e.g. De Morgan push-down) happens here — that's
-- the simplifier's job in empty.lua. Per CLAUDE.md the constructor performs
-- only the cheap, semantics-preserving rewrites that every caller would
-- otherwise reimplement.
--: (V4Type) -> V4Type
function M.neg(body)
	if body.tag == "top" then
		return BOT
	elseif body.tag == "bot" then
		return TOP
	elseif body.tag == "neg" then
		return body.body
	else
		return { tag = M.TAG_NEG, body = body }
	end
end

-- Forall constructor. `f` is invoked with a list of fresh "bound" V4Vars (one
-- per name) and must return the body type. The vars are ordinary V4Vars (we
-- don't introduce a separate "bound var" tag — substitution distinguishes
-- "bound here" from "free" by membership in the forall's `vars` list at
-- instantiate/skolemize time). The bound vars MUST NOT receive bounds during
-- solving; the instantiation/skolemization step substitutes them out before
-- any constraint is added to either side.
--: (string[], (V4Type[]) -> V4Type) -> V4Type
function M.forall(names, f)
	local vars = {} --[[: V4Type[] ]]
	for i, n in ipairs(names) do vars[i] = M.var(n) end
	local body = f(vars)
	return { tag = M.TAG_FORALL, vars = vars, body = body }
end

-- Lower-level forall constructor for callers building the body manually
-- (e.g. test fixtures that already have the bound-var handles).
--: (V4Type[], V4Type) -> V4Type
function M.forall_raw(vars, body)
	return { tag = M.TAG_FORALL, vars = vars, body = body }
end

-- Fresh skolem constant. Each skolem gets a unique id; equality (and hence
-- subtype reflexivity) is by identity. Skolems are not user-facing — they
-- arise only as a byproduct of subsumption against a forall on the right.
local _next_skolem_id = 0
--: (string | nil) -> V4Type
function M.skolem(name)
	_next_skolem_id = _next_skolem_id + 1
	return { tag = M.TAG_SKOLEM, id = _next_skolem_id, name = name or ("σ" .. _next_skolem_id) }
end

function M._reset_skolem_ids() _next_skolem_id = 0 end

-- ── Display ───────────────────────────────────────────────────────────────
-- A minimal pretty-printer for error messages and test diagnostics. Does NOT
-- coalesce bounds into a compact type — that's a later-phase concern.

-- Cycle protection during display uses two seen-sets keyed by id:
--   `seen_var[var_id] = true` while we're inside a variable's bound expansion
--   `seen_mu[mu_id]   = name`  while we're inside a mu node — the value is
--     the bound name (`X1`, `X2`, ...) used for back-references.
--:: ShowSeen = { vars: { [integer]: boolean }, mus: { [integer]: string } }

--: (V4Type, ShowSeen) -> string
local function show(t, seen)
	if t.tag == "top" then return "unknown" end
	if t.tag == "bot" then return "never" end
	if t.tag == "prim" then return t.name end
	if t.tag == "literal" then
		if t.base == "string" then return string.format("%q", t.value) end
		return tostring(t.value)
	end
	if t.tag == "fn" then
		local ps = {}
		for i, p in ipairs(t.params) do ps[i] = show(p, seen) end
		return "(" .. table.concat(ps, ", ") .. ") -> " .. show(t.ret, seen)
	end
	if t.tag == "rec" then
		local parts = {} --[[: { [integer]: string } ]]
		-- Sort keys for deterministic output.
		local keys = {} --[[: { [integer]: string } ]]
		for k in pairs(t.fields) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local v = t.fields[k]
			if v ~= nil then
				parts[#parts + 1] = k .. ": " .. show(v, seen)
			end
		end
		local ix = t.indexer
		if ix ~= nil then
			parts[#parts + 1] = "[" .. show(ix.key, seen) .. "]: " .. show(ix.value, seen)
		end
		if t.open then parts[#parts + 1] = "..." end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	if t.tag == "union" then
		local ps = {}
		for i, m in ipairs(t.members) do ps[i] = show(m, seen) end
		return "(" .. table.concat(ps, " | ") .. ")"
	end
	if t.tag == "inter" then
		local ps = {}
		for i, m in ipairs(t.members) do ps[i] = show(m, seen) end
		return "(" .. table.concat(ps, " & ") .. ")"
	end
	if t.tag == "neg" then
		return "~" .. show(t.body, seen)
	end
	if t.tag == "mu" then
		-- Re-encountering the same mu node: emit the bound name only.
		local existing = seen.mus[t.id]
		if existing ~= nil then return existing end
		-- First visit: assign a bound name and recurse into the body. The
		-- name is `X<id>` rather than a count-of-active-mus because nested
		-- mus need distinct names and we want stability across runs.
		local name = "X" .. t.id
		seen.mus[t.id] = name
		local body_str = show(t.body, seen)
		seen.mus[t.id] = nil
		-- MLstruct §3.5 / simple-sub §4 coalescing form: `μ X. body`.
		return "(μ " .. name .. ". " .. body_str .. ")"
	end
	if t.tag == "var" then
		-- Cycle protection: a variable may transitively bound itself. Keyed
		-- by var id so the typechecker can express the seen-set as a map.
		if seen.vars[t.id] then return t.name end
		seen.vars[t.id] = true
		if #t.lower == 0 and #t.upper == 0 then
			seen.vars[t.id] = nil
			return t.name
		end
		local lows, ups = {}, {}
		for i, b in ipairs(t.lower) do lows[i] = show(b, seen) end
		for i, b in ipairs(t.upper) do ups[i] = show(b, seen) end
		local parts = { t.name }
		if #lows > 0 then parts[#parts + 1] = "[>: " .. table.concat(lows, ", ") .. "]" end
		if #ups > 0 then parts[#parts + 1] = "[<: " .. table.concat(ups, ", ") .. "]" end
		seen.vars[t.id] = nil
		return table.concat(parts, " ")
	end
	if t.tag == "forall" then
		local names = {} --[[: { [integer]: string } ]]
		for i, v in ipairs(t.vars) do
			if v.tag == "var" then names[i] = v.name else names[i] = "?" end
		end
		return "(∀ " .. table.concat(names, " ") .. ". " .. show(t.body, seen) .. ")"
	end
	if t.tag == "skolem" then return "#" .. t.name end
	return "?<" .. tostring(t.tag) .. ">"
end

--: (V4Type) -> string
function M.show(t) return show(t, { vars = {}, mus = {} }) end

return M
