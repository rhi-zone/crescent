-- lib/type/analysis/slice_ty.lua
--
-- The `Ty` grammar and hash-cons interner for `crescent.slice.v1`
-- (docs/agnostic-static-analysis-crescent-slice.md §1, §3.1, §3.3).
--
-- This is Pass 1 of the slice mechanization (§8): a pure, self-contained value
-- universe and its interner. NO claims, evidence, or substrate objects appear
-- here — `slice_subtype.lua` is the only consumer in Pass 1, and the substrate
-- (init.lua) is not imported. The interner is what makes the cycle-guarded
-- coinductive subtype relation terminate (§3.3): structural identity collapses
-- to tid identity, so the "already seen (A, B)" guard is an O(1) tid-pair test.
--
-- Equirecursive μ is hash-consed from day one (kernel §3.3, the TODO:826 fix).
-- To make alpha-equivalent μ types share a tid, bound variables are stored
-- internally as de Bruijn indices: `tyvar(k)` refers to the k-th enclosing `mu`
-- binder (1 = nearest). The public constructors `mu`/`tyvar` accept named vars
-- for ergonomics and lower them to de Bruijn at intern time; two μ types that
-- differ only in bound-variable name therefore intern to the same tid.
--
-- Every Ty is a frozen, interned table carrying a `tid` (an integer) and a
-- `kind` tag-literal. Structural equality ⇔ tid equality, by construction.
--
-- The deferral fence (docs/decisions/kernel-recommendation.md §3) is honored:
-- NO complement, match types, RDNF, parametric polymorphism, HKT, or effects
-- appear in this grammar — not even "for later convenience".

local M = {}

-- ── Ty kind tags ─────────────────────────────────────────────────────────────
--
-- (`--::` declarations must each be a single line — multiline continuation is
-- not supported by the annotation parser.)
--
--:: TyKind = "nil" | "boolean" | "number" | "integer" | "string" | "function" | "unknown" | "never" | "lit_bool" | "lit_int" | "lit_num" | "lit_str" | "fn" | "rec" | "indexer" | "rec_with_indexer" | "union" | "inter" | "mu" | "tyvar"
--:: Field  = { key: string, ty: Ty, optional: boolean, readonly: boolean }
--:: Params = { fixed: Ty[], vararg?: Ty }
--:: Ret    = { fixed: Ty[], vararg?: Ty }
--:: Rows   = "closed" | "open"
--:: Indexer = { key: Ty, val: Ty }
--:: Ty = { tid: integer, kind: TyKind, b?: boolean, n?: number, s?: string, params?: Params, ret?: Ret, fields?: Field[], rows?: Rows, key?: Ty, val?: Ty, members?: Ty[], body?: Ty, idx?: integer }

-- ── Interner state ───────────────────────────────────────────────────────────
--
-- `_table` maps a structural key string → interned Ty. `_next_tid` is the tid
-- allocator. The interner is module-global and append-only; tids never change
-- once assigned, so a Ty captured before a later intern keeps its tid.

local _table   = {} --[[: { [string]: Ty } ]]
local _next_tid = 0 --: integer

-- Reset the interner. Tests use this to keep tids small/deterministic; it is NOT
-- part of the production path (subtype correctness never depends on tid values,
-- only on tid identity within a single interner generation).
--: () -> nil
function M.reset()
	_table    = {}
	_next_tid = 0
end

-- Intern a freshly-built node by its structural key. The node's child fields
-- must already be interned Ty values (so their tids are stable). Returns the
-- canonical interned Ty (the input node if new, else the existing one).
--: (string, Ty) -> Ty
local function intern(key, node)
	local hit = _table[key]
	if hit then return hit end
	_next_tid   = _next_tid + 1
	node.tid    = _next_tid
	_table[key] = node
	return node
end

-- ── Primitives and top/bottom ────────────────────────────────────────────────
--
-- Each primitive is a singleton interned once. They are built lazily on first
-- access so M.reset() (tests) re-creates them in the fresh interner generation.

--: (TyKind) -> Ty
local function prim(kind)
	return intern("P:" .. kind, { kind = kind, tid = 0 })
end

--: () -> Ty
function M.nil_()    return prim("nil") end
--: () -> Ty
function M.boolean() return prim("boolean") end
--: () -> Ty
function M.number()  return prim("number") end
--: () -> Ty
function M.integer() return prim("integer") end
--: () -> Ty
function M.string()  return prim("string") end
--: () -> Ty
function M.func()    return prim("function") end
--: () -> Ty
function M.unknown() return prim("unknown") end
--: () -> Ty
function M.never()   return prim("never") end

-- ── Literal singletons ───────────────────────────────────────────────────────

--: (boolean) -> Ty
function M.lit_bool(b)
	return intern("LB:" .. tostring(b), { kind = "lit_bool", b = b, tid = 0 })
end

-- A lit_int must carry an INTEGER-VALUED number (audit round 1, finding 2). A
-- non-integer (`3.5`) is rejected with (nil, errmsg) — it would otherwise collide
-- with `lit_int(3)` via the old `%d` key (which truncated 3.5 → "3") AND be
-- unsound (`lit_int(3.5) <: integer` is wrong; 3.5 is not an integer). The key
-- uses `%.17g` so the interned identity is over the exact double value, never a
-- truncation. Note (2^53 precision boundary, documented in tests): integers beyond
-- 2^53 are not exactly representable as doubles, so `lit_int(2^53)` and
-- `lit_int(2^53 + 1)` denote the SAME double and SHARE a tid — a fundamental
-- IEEE-754 limitation of representing integers as Lua/LuaJIT numbers, not a bug;
-- both are integer-valued and well-formed.
--: (number) -> (Ty | nil, string | nil)
function M.lit_int(n)
	if type(n) ~= "number" then return nil, "lit_int requires a number" end
	if n ~= n or n == math.huge or n == -math.huge then
		return nil, "lit_int requires a finite integer-valued number"
	end
	if n % 1 ~= 0 then
		return nil, "lit_int requires an integer-valued number, got " .. tostring(n)
	end
	return intern("LI:" .. string.format("%.17g", n), { kind = "lit_int", n = n, tid = 0 })
end

--: (number) -> Ty
function M.lit_num(x)
	-- %.17g round-trips a double exactly; distinct doubles get distinct keys.
	return intern("LN:" .. string.format("%.17g", x), { kind = "lit_num", n = x, tid = 0 })
end

--: (string) -> Ty
function M.lit_str(s)
	-- %q makes the key injective over string content (escapes embedded quotes).
	return intern("LS:" .. string.format("%q", s), { kind = "lit_str", s = s, tid = 0 })
end

-- ── Structural key helpers ───────────────────────────────────────────────────
--
-- Children are already interned, so their tids form a stable structural key.

--: (Ty[]) -> string
local function tids(list)
	local parts = {} --[[: { [integer]: string } ]]
	for i = 1, #list do parts[#parts + 1] = tostring(list[i].tid) end
	return table.concat(parts, ",")
end

--: (Ty | nil) -> string
local function opt_tid(t)
	if t == nil then return "_" end
	return tostring(t.tid)
end

-- ── Functions ────────────────────────────────────────────────────────────────
--
-- Params/Ret are return/parameter tuples with an optional trailing vararg spread
-- (§1.2). A multi-return `() -> (A, B)` is `ret = { fixed = {A, B} }`.

--: (Params) -> Params
local function norm_pr(pr)
	return { fixed = pr.fixed or {}, vararg = pr.vararg }
end

--: (Params, Ret) -> Ty
function M.fn(params, ret)
	local p = norm_pr(params)
	local r = norm_pr(ret)
	local key = "FN:" .. tids(p.fixed) .. "|" .. opt_tid(p.vararg)
		.. ">" .. tids(r.fixed) .. "|" .. opt_tid(r.vararg)
	return intern(key, { kind = "fn", params = p, ret = r, tid = 0 })
end

-- ── Records / indexers ───────────────────────────────────────────────────────
--
-- A Field is { key, ty, optional, readonly }. Field order is NOT part of
-- structural identity (records are unordered by key), so fields are sorted by
-- key before keying. `rows` is "closed" | "open" (the `...` structural marker).

--: (Field[]) -> Field[]
local function norm_fields(fields)
	local out = {} --[[: { [integer]: Field } ]]
	for i = 1, #fields do
		local f = fields[i]
		out[#out + 1] = {
			key      = f.key,
			ty       = f.ty,
			optional = f.optional or false,
			readonly = f.readonly or false,
		}
	end
	table.sort(out, function(a, b) return a.key < b.key end)
	return out
end

--: (Field[]) -> string
local function fields_key(fields)
	local parts = {} --[[: { [integer]: string } ]]
	for i = 1, #fields do
		local f = fields[i]
		parts[#parts + 1] = string.format("%q", f.key) .. ":" .. tostring(f.ty.tid)
			.. (f.optional and "?" or "") .. (f.readonly and "!" or "")
	end
	return table.concat(parts, ";")
end

--: (Field[], Rows) -> Ty
function M.rec(fields, rows)
	local fs = norm_fields(fields)
	rows = rows or "closed"
	local key = "REC:" .. fields_key(fs) .. "|" .. rows
	return intern(key, { kind = "rec", fields = fs, rows = rows, tid = 0 })
end

--: (Ty, Ty) -> Ty
function M.indexer(key_ty, val_ty)
	local k = "IDX:" .. tostring(key_ty.tid) .. ">" .. tostring(val_ty.tid)
	return intern(k, { kind = "indexer", key = key_ty, val = val_ty, tid = 0 })
end

--: (Field[], Rows, { key: Ty, val: Ty }) -> Ty
function M.rec_with_indexer(fields, rows, idx)
	local fs = norm_fields(fields)
	rows = rows or "closed"
	local key = "RWI:" .. fields_key(fs) .. "|" .. rows
		.. "|" .. tostring(idx.key.tid) .. ">" .. tostring(idx.val.tid)
	return intern(key, {
		kind   = "rec_with_indexer",
		fields = fs,
		rows   = rows,
		key    = idx.key,
		val    = idx.val,
		tid    = 0,
	})
end

-- ── Union / intersection ─────────────────────────────────────────────────────
--
-- Members are flattened (a union of unions is one union), deduplicated by tid,
-- and sorted by tid so identity is order-insensitive (§3.4: `A | B` = set union).
-- Normalization laws applied at construction:
--   union: drop `never` members; union([]) = never; singleton union = its member;
--          unknown-absorbs (a union containing unknown is unknown).
--   inter: drop `unknown` members; inter([]) = unknown; singleton = its member;
--          never-absorbs (an inter containing never is never).
-- These are the lattice-identity normalizations; they are sound (set-theoretic)
-- and keep interned forms canonical so the subtype lattice laws (§3.5) hold by
-- construction wherever they are exact.

--: (Ty[], string) -> Ty[]
local function flatten(members, kind)
	local out = {} --[[: Ty[] ]]
	for i = 1, #members do
		local m = members[i]
		if m.kind == kind then
			local sub = m.members or {} --[[: Ty[] ]]
			for j = 1, #sub do out[#out + 1] = sub[j] end
		else
			out[#out + 1] = m
		end
	end
	return out
end

--: ({ [integer]: Ty }) -> { [integer]: Ty }
local function dedup_sorted(members)
	-- Manual insertion sort by tid (avoids table.sort's generic-V bleed over the
	-- structural `Ty` shape — the documented cli.lua workaround, force-cast-free
	-- since we only ever read the required `.tid` field).
	for i = 2, #members do
		local key = members[i]
		local j   = i - 1
		while j >= 1 and members[j].tid > key.tid do
			members[j + 1] = members[j]
			j = j - 1
		end
		members[j + 1] = key
	end
	local out  = {} --[[: { [integer]: Ty } ]]
	local last = nil --: integer | nil
	for i = 1, #members do
		local m = members[i]
		if m.tid ~= last then
			out[#out + 1] = m
			last = m.tid
		end
	end
	return out
end

--: (Ty[]) -> Ty
function M.union(members)
	local flat = flatten(members, "union")
	local kept = {} --[[: { [integer]: Ty } ]]
	for i = 1, #flat do
		local m = flat[i]
		if m.kind == "unknown" then return M.unknown() end -- unknown absorbs
		if m.kind ~= "never" then kept[#kept + 1] = m end   -- drop never
	end
	kept = dedup_sorted(kept)
	if #kept == 0 then return M.never() end
	if #kept == 1 then return kept[1] end
	return intern("U:" .. tids(kept), { kind = "union", members = kept, tid = 0 })
end

--: (Ty[]) -> Ty
function M.inter(members)
	local flat = flatten(members, "inter")
	local kept = {} --[[: { [integer]: Ty } ]]
	for i = 1, #flat do
		local m = flat[i]
		if m.kind == "never" then return M.never() end       -- never absorbs
		if m.kind ~= "unknown" then kept[#kept + 1] = m end   -- drop unknown
	end
	kept = dedup_sorted(kept)
	if #kept == 0 then return M.unknown() end
	if #kept == 1 then return kept[1] end
	return intern("I:" .. tids(kept), { kind = "inter", members = kept, tid = 0 })
end

-- ── Equirecursive μ / tyvar (de Bruijn) ──────────────────────────────────────
--
-- Public API uses named binders for ergonomics:
--   M.mu("X", function(x) return <body using x> end)
-- where `x` is the bound `tyvar`. Internally `tyvar` carries a de Bruijn index
-- `idx` (1 = nearest enclosing μ), so alpha-equivalent μ types share a tid.
--
-- During body construction the bound variable's depth is not yet known (the body
-- may nest further μ), so a `tyvar` is created as a *placeholder* carrying the
-- binder's unique build-time token; M.mu then rewrites placeholders to de Bruijn
-- indices relative to their binding depth and interns the closed result. This
-- keeps the interner's stored nodes fully de-Bruijn (hence alpha-canonical).

-- A unique token per in-flight μ binder.
local _binder_seq = 0 --: integer

-- Build a placeholder tyvar bound to `token`. Placeholders are *interned*
-- sentinels carrying a negative idx (= -token), distinct per token, so a body
-- tree containing them interns consistently — including when an inner `M.mu`
-- interns a subtree that still holds an outer binder's placeholder (which the
-- outer `M.mu` rewrites later). The interner thus stays sound across nested μ.
--: (integer) -> Ty
local function placeholder(token)
	return intern("PH:" .. tostring(token), { kind = "tyvar", idx = -token, tid = 0 })
end

-- Intern a de Bruijn tyvar at index `i` (1 = nearest binder).
--: (integer) -> Ty
local function tyvar_db(i)
	return intern("V:" .. tostring(i), { kind = "tyvar", idx = i, tid = 0 })
end

-- Recursively rebuild `node`, converting placeholder tyvars (idx = -token) bound
-- to `token` into de Bruijn tyvars at `depth`, and re-interning every node so the
-- result is canonical. `depth` is the number of μ binders between the root of
-- this rewrite and the current position (the binder itself is depth 1).
--
-- Nodes that contain no placeholder for `token` are already interned and returned
-- as-is (their subtree is closed w.r.t. this binder). We detect that cheaply: a
-- node already carries a positive tid iff it is interned; placeholders carry
-- tid = -1, so any subtree containing one is un-interned along its spine.

-- Safe field accessors. By construction a node of a given kind always carries
-- its kind's fields, but the structural `Ty` shape makes them optional; these
-- read them with a definite fallback so the rewriters need no force casts.
--: (Ty) -> Params
local function get_params(node) return node.params or ({ fixed = {} } --[[: Params ]]) end
--: (Ty) -> Ret
local function get_ret(node) return node.ret or ({ fixed = {} } --[[: Ret ]]) end
--: (Ty) -> Field[]
local function get_fields(node) return node.fields or {} end
--: (Ty) -> Ty[]
local function get_members(node) return node.members or {} end
--: (Ty) -> Ty
local function get_body(node) return node.body or M.never() end
--: (Ty) -> Ty
local function get_key(node) return node.key or M.never() end
--: (Ty) -> Ty
local function get_val(node) return node.val or M.never() end

-- ── Generic structural rebuild ───────────────────────────────────────────────
--
-- `rebuild(node, xf, binders)` rewrites a `Ty` by applying `xf` to every leaf
-- it must transform (`tyvar` occurrences), threading `binders` (the number of
-- μ binders crossed from the rewrite root). Each compound constructor maps its
-- children recursively; `mu` increments `binders`. Both `close_over` and `subst`
-- are expressed as a leaf transform over this one rebuild, so the optional-field
-- handling lives in exactly one place.

--: (Ty, (Ty, integer) -> Ty, integer) -> Ty
local function rebuild(node, xf, binders)
	local kind = node.kind
	if kind == "tyvar" then
		return xf(node, binders)
	elseif kind == "fn" then
		local p = get_params(node)
		local r = get_ret(node)
		local nf  = {} --[[: Ty[] ]]
		local nrf = {} --[[: Ty[] ]]
		for i = 1, #p.fixed do nf[#nf + 1]  = rebuild(p.fixed[i], xf, binders) end
		for i = 1, #r.fixed do nrf[#nrf + 1] = rebuild(r.fixed[i], xf, binders) end
		return M.fn(
			{ fixed = nf,  vararg = p.vararg and rebuild(p.vararg, xf, binders) or nil },
			{ fixed = nrf, vararg = r.vararg and rebuild(r.vararg, xf, binders) or nil }
		)
	elseif kind == "rec" or kind == "rec_with_indexer" then
		local fields = get_fields(node)
		local nf = {} --[[: Field[] ]]
		for i = 1, #fields do
			local f = fields[i]
			nf[#nf + 1] = { key = f.key, ty = rebuild(f.ty, xf, binders), optional = f.optional, readonly = f.readonly }
		end
		if kind == "rec" then
			return M.rec(nf, node.rows or "closed")
		else
			return M.rec_with_indexer(nf, node.rows or "closed", {
				key = rebuild(get_key(node), xf, binders),
				val = rebuild(get_val(node), xf, binders),
			})
		end
	elseif kind == "indexer" then
		return M.indexer(rebuild(get_key(node), xf, binders), rebuild(get_val(node), xf, binders))
	elseif kind == "union" or kind == "inter" then
		local ms = get_members(node)
		local nm = {} --[[: Ty[] ]]
		for i = 1, #ms do nm[#nm + 1] = rebuild(ms[i], xf, binders) end
		return kind == "union" and M.union(nm) or M.inter(nm)
	elseif kind == "mu" then
		return M.mu_raw(rebuild(get_body(node), xf, binders + 1))
	end
	-- primitives / literals: no children.
	return node
end

-- Close `body` over an in-flight binder: convert placeholder tyvars (idx = -token)
-- into de Bruijn tyvars at the binding depth. `binders` starts at 0 (the binder
-- itself is reached at de Bruijn index `binders + 1`).
--: (Ty, integer) -> Ty
local function close_over(body, token)
	return rebuild(body, function(tv, binders)
		if tv.idx == -token then return tyvar_db(binders + 1) end
		return tv
	end, 0)
end

-- Intern a μ over an already-de-Bruijn body (body's index 1 refers to THIS μ).
--: (Ty) -> Ty
function M.mu_raw(body)
	return intern("MU:" .. tostring(body.tid), { kind = "mu", body = body, tid = 0 })
end

-- Public μ constructor. `f` receives the bound tyvar placeholder and returns the
-- body. Example:
--   local nat = M.mu("X", function(x)
--     return M.union({ M.nil_(), M.rec({ { key = "next", ty = x } }, "closed") })
--   end)
--: (string, (Ty) -> Ty) -> Ty
function M.mu(_name, f)
	_binder_seq = _binder_seq + 1
	local token = _binder_seq
	local body  = f(placeholder(token))
	local closed = close_over(body, token)
	return M.mu_raw(closed)
end

-- ── Unfolding ────────────────────────────────────────────────────────────────
--
-- Equirecursive one-step unfold: μX.T  ↦  T[μX.T / X]. Substitutes the μ itself
-- for every de Bruijn index that refers to the outermost binder. Used by the
-- subtype relation (§3.2) and the μ-unfolding fuzz invariant (§3.5).

-- One-step unfold of a μ type. `mu_ty` must have kind "mu". Substitutes `mu_ty`
-- itself for the outermost de Bruijn variable (index 1, shifted by intervening
-- μ binders), via the shared `rebuild`.
--: (Ty) -> Ty
function M.unfold(mu_ty)
	if mu_ty.kind ~= "mu" then return mu_ty end
	return rebuild(get_body(mu_ty), function(tv, binders)
		if tv.idx == binders + 1 then return mu_ty end
		return tv
	end, 0)
end

-- ── Introspection ────────────────────────────────────────────────────────────

--: (Ty, Ty) -> boolean
function M.equal(a, b) return a.tid == b.tid end

return M
