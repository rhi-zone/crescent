-- lib/type/analysis/slice_ty_arg.lua
--
-- The `Ty` ⇄ `ArgValue` bridge for `crescent.slice.v1`
-- (docs/agnostic-static-analysis-crescent-slice.md §2). Types ride claim args as
-- plain serializable data (the substrate's `ArgValue`), exactly as STLC's `Type`
-- did. An interned `Ty` (slice_ty.lua) is NOT directly serializable: it carries a
-- `tid`, cross-references to other interned nodes, and de-Bruijn `tyvar` indices.
-- So this module defines a PORTABLE encoding — a plain tag-tree with no tids —
-- and the inverse `parse-not-cast` decoder that re-interns the tree through the
-- slice_ty constructors.
--
-- Discipline (the hosted-checker trust obligation, STLC's parse_type pattern):
-- the decoder validates the ArgValue tree and reconstructs an interned Ty,
-- returning nil on any malformed input. It NEVER force-casts opaque args to Ty.
--
-- Also hosts `type_shape_check` well-formedness, INCLUDING μ contractiveness
-- (§9.3 finding 1): a μ whose bound variable occurs unguarded — as a bare union/
-- inter member rather than under a `rec`/`indexer`/`fn` constructor — is
-- ill-formed and rejected, never silently read as top. The `...`-vs-indexer
-- distinction is structural in the grammar (open `rows` vs `indexer` node), so it
-- needs no extra check here; it is preserved by faithful round-tripping.

local G = require("lib.type.analysis.slice_ty")

local M = {}

-- ── Portable encoding ────────────────────────────────────────────────────────
--
-- A PTy is a plain ArgValue tree. Bound μ variables are encoded by NAME (a fresh
-- name per binder, allocated at encode time), so two alpha-equivalent μ types
-- encode to structurally-equal trees once decoded back through the interner
-- (which lowers names to de Bruijn). The encoding mirrors the grammar:
--   { k="nil" } | { k="number" } | ... primitives
--   { k="lit_int", n=42 } | { k="lit_str", s="GET" } | { k="lit_bool", b=true } | { k="lit_num", n=3.14 }
--   { k="fn", params={fixed={PTy..}, vararg=PTy?}, ret={fixed={PTy..}, vararg=PTy?} }
--   { k="rec", fields={ {key,ty,optional,readonly}.. }, rows="closed"|"open" }
--   { k="indexer", key=PTy, val=PTy }
--   { k="rec_with_indexer", fields={..}, rows, key=PTy, val=PTy }
--   { k="union"|"inter", members={ PTy.. } }
--   { k="mu", var="X", body=PTy }
--   { k="tyvar", var="X" }                  (free reference to an enclosing mu var)
--
--:: PField = { key: string, ty: PTy, optional?: boolean, readonly?: boolean }
--:: PTy = { k: string, n?: number, s?: string, b?: boolean, params?: { fixed: PTy[], vararg?: PTy }, ret?: { fixed: PTy[], vararg?: PTy }, fields?: PField[], rows?: string, key?: PTy, val?: PTy, members?: PTy[], var?: string, body?: PTy }

-- ── Encode: interned Ty -> portable PTy ──────────────────────────────────────
--
-- De-Bruijn `tyvar(idx)` is re-named to a synthetic name keyed on its binding
-- depth, so the round-trip is faithful. `binders` is a stack of the names
-- allocated for the μ binders currently in scope (innermost last).

local PRIM = {
	["nil"] = true, boolean = true, number = true, integer = true,
	string = true, ["function"] = true, unknown = true, never = true,
}

--: (Ty, { [integer]: string | nil }) -> PTy
local function encode(ty, binders)
	local k = ty.kind
	if PRIM[k] then return { k = k } end
	if k == "lit_bool" then return { k = k, b = ty.b == true } end
	if k == "lit_int" then return { k = k, n = ty.n or 0 } end
	if k == "lit_num" then return { k = k, n = ty.n or 0 } end
	if k == "lit_str" then return { k = k, s = ty.s or "" } end
	if k == "fn" then
		local p = ty.params or ({ fixed = {} } --[[: Params ]])
		local r = ty.ret or ({ fixed = {} } --[[: Ret ]])
		local pf = {} --[[: PTy[] ]]
		local rf = {} --[[: PTy[] ]]
		for i = 1, #p.fixed do pf[i] = encode(p.fixed[i], binders) end
		for i = 1, #r.fixed do rf[i] = encode(r.fixed[i], binders) end
		local pva = p.vararg --[[: Ty | nil ]]
		local rva = r.vararg --[[: Ty | nil ]]
		return {
			k = "fn",
			params = { fixed = pf, vararg = pva ~= nil and encode(pva, binders) or nil },
			ret = { fixed = rf, vararg = rva ~= nil and encode(rva, binders) or nil },
		}
	end
	if k == "rec" or k == "rec_with_indexer" then
		local fields = ty.fields or {}
		local fs = {} --[[: PField[] ]]
		for i = 1, #fields do
			local f = fields[i]
			fs[i] = { key = f.key, ty = encode(f.ty, binders), optional = f.optional, readonly = f.readonly }
		end
		local out = { k = k, fields = fs, rows = ty.rows or "closed" } --[[: PTy ]]
		if k == "rec_with_indexer" then
			out.key = encode(ty.key or G.never(), binders)
			out.val = encode(ty.val or G.never(), binders)
		end
		return out
	end
	if k == "indexer" then
		return { k = "indexer", key = encode(ty.key or G.never(), binders), val = encode(ty.val or G.never(), binders) }
	end
	if k == "union" or k == "inter" then
		local ms = ty.members or {}
		local out = {} --[[: PTy[] ]]
		for i = 1, #ms do out[i] = encode(ms[i], binders) end
		return { k = k, members = out }
	end
	if k == "mu" then
		local depth = #binders + 1
		local name = "X" .. tostring(depth)
		binders[depth] = name
		local body = encode(ty.body or G.never(), binders)
		binders[depth] = nil
		return { k = "mu", var = name, body = body }
	end
	if k == "tyvar" then
		-- de Bruijn idx 1 = innermost binder = binders[#binders].
		local idx = ty.idx or 1
		local name = binders[#binders - (idx - 1)]
		return { k = "tyvar", var = name or ("?" .. tostring(idx)) }
	end
	-- Unknown kind: encode defensively as unknown (never reached for valid Ty).
	return { k = "unknown" }
end

--: (Ty) -> PTy
function M.encode(ty) return encode(ty, {}) end

-- ── Decode: portable PTy -> interned Ty (parse-not-cast) ─────────────────────
--
-- `env` maps an in-scope μ binder name to its placeholder tyvar (produced by
-- G.mu's callback). Returns nil on any malformed node — the trust discipline.

local decode --[[: (unknown, { [string]: Ty }) -> Ty | nil ]]

--: (unknown, { [string]: Ty }) -> { fixed: Ty[], vararg?: Ty } | nil
local function decode_pr(v, env)
	if type(v) ~= "table" then return nil end
	local fixed = v.fixed
	if fixed ~= nil and type(fixed) ~= "table" then return nil end
	local out = {} --[[: Ty[] ]]
	if type(fixed) == "table" then
		for i = 1, #fixed do
			local d = decode(fixed[i], env)
			if not d then return nil end
			out[i] = d
		end
	end
	local va --[[: Ty | nil ]]
	if v.vararg ~= nil then
		va = decode(v.vararg, env)
		if not va then return nil end
	end
	return { fixed = out, vararg = va }
end

--: (unknown, { [string]: Ty }) -> Ty | nil
decode = function(v, env)
	if type(v) ~= "table" then return nil end
	local k = v.k
	if type(k) ~= "string" then return nil end

	if k == "nil" then return G.nil_() end
	if k == "boolean" then return G.boolean() end
	if k == "number" then return G.number() end
	if k == "integer" then return G.integer() end
	if k == "string" then return G.string() end
	if k == "function" then return G.func() end
	if k == "unknown" then return G.unknown() end
	if k == "never" then return G.never() end

	if k == "lit_bool" then
		if type(v.b) ~= "boolean" then return nil end
		return G.lit_bool(v.b)
	end
	if k == "lit_int" then
		if type(v.n) ~= "number" then return nil end
		-- validate integer-valuedness in the decoder too (audit round 1, finding 2):
		-- a `{k="lit_int", n=3.5}` from an untrusted producer must be rejected, not
		-- silently truncated/collided. G.lit_int now returns (nil, errmsg) on a
		-- non-integer; the codec turns that into a decode failure (parse-not-cast).
		local lit = G.lit_int(v.n)
		if not lit then return nil end
		return lit
	end
	if k == "lit_num" then
		if type(v.n) ~= "number" then return nil end
		return G.lit_num(v.n)
	end
	if k == "lit_str" then
		if type(v.s) ~= "string" then return nil end
		return G.lit_str(v.s)
	end

	if k == "fn" then
		local p = decode_pr(v.params == nil and { fixed = {} } or v.params, env)
		local r = decode_pr(v.ret == nil and { fixed = {} } or v.ret, env)
		if not p or not r then return nil end
		return G.fn(p, r)
	end

	if k == "rec" or k == "rec_with_indexer" then
		local vfields = v.fields
		if type(vfields) ~= "table" then return nil end
		local fs = {} --[[: Field[] ]]
		for i = 1, #vfields do
			local f = vfields[i]
			if type(f) ~= "table" then return nil end
			local fkey = f.key
			if type(fkey) ~= "string" then return nil end
			local fty = decode(f.ty, env)
			if not fty then return nil end
			fs[i] = { key = fkey, ty = fty, optional = f.optional == true, readonly = f.readonly == true }
		end
		local rows = v.rows
		if rows ~= "open" and rows ~= "closed" and rows ~= nil then return nil end
		if k == "rec" then
			return G.rec(fs, rows or "closed")
		end
		local ik = decode(v.key, env)
		local iv = decode(v.val, env)
		if not ik or not iv then return nil end
		return G.rec_with_indexer(fs, rows or "closed", { key = ik, val = iv })
	end

	if k == "indexer" then
		local ik = decode(v.key, env)
		local iv = decode(v.val, env)
		if not ik or not iv then return nil end
		return G.indexer(ik, iv)
	end

	if k == "union" or k == "inter" then
		local vmembers = v.members
		if type(vmembers) ~= "table" then return nil end
		local ms = {} --[[: Ty[] ]]
		for i = 1, #vmembers do
			local d = decode(vmembers[i], env)
			if not d then return nil end
			ms[i] = d
		end
		return k == "union" and G.union(ms) or G.inter(ms)
	end

	if k == "mu" then
		local name = v.var
		if type(name) ~= "string" then return nil end
		local body_ok = true --: boolean
		local mu = G.mu(name, function(placeholder)
			-- Bind the name to the placeholder while decoding the body; restore
			-- the previous binding (shadowing nested μ with the same name).
			local prev = env[name]
			env[name] = placeholder
			local body = decode(v.body, env)
			env[name] = prev
			if not body then body_ok = false; return G.never() end
			return body
		end)
		if not body_ok then return nil end
		return mu
	end

	if k == "tyvar" then
		local name = v.var
		if type(name) ~= "string" then return nil end
		local bound = env[name]
		if not bound then return nil end -- free tyvar (unbound) is malformed
		return bound
	end

	return nil
end

--: (unknown) -> Ty | nil
function M.decode(v) return decode(v, {}) end

-- ── Portable-tree σ substitution (local generic instantiation, §2.4) ─────────
--
-- A generic callee type is carried as a PTy whose type parameters appear as FREE
-- `{ k="tyvar", var=name }` nodes (never interned — free tyvars are not a grammar
-- construct). σ-application substitutes each free tyvar named in `subst` with its
-- replacement PTy, producing a monomorphic PTy. μ-bound tyvars are NOT free: a
-- `mu` binder shadows σ for its own variable name, so substitution skips a tyvar
-- whose name is bound by an enclosing μ in the tree. Returns the substituted PTy,
-- or nil on malformed input.

local subst_pty --[[: (unknown, { [string]: unknown }, { [string]: boolean | nil }) -> unknown ]]

--: (unknown, { [string]: unknown }, { [string]: boolean | nil }) -> unknown
subst_pty = function(v, subst, bound)
	if type(v) ~= "table" then return v end
	local k = v.k
	if k == "tyvar" then
		local name = v.var
		if type(name) == "string" and not bound[name] and subst[name] ~= nil then
			return subst[name]
		end
		return v
	end
	if k == "mu" then
		local name = v.var
		if type(name) == "string" then
			local prev = bound[name]
			bound[name] = true
			local body = subst_pty(v.body, subst, bound)
			bound[name] = prev
			return { k = "mu", var = name, body = body }
		end
		return { k = "mu", var = name, body = subst_pty(v.body, subst, bound) }
	end
	if k == "fn" then
		local p = v.params --[[: unknown ]]
		local r = v.ret --[[: unknown ]]
		--: (unknown) -> unknown
		local function pr(x)
			if type(x) ~= "table" then return { fixed = {} } end
			local fixed = x.fixed
			local out = {} --[[: { [integer]: unknown } ]]
			if type(fixed) == "table" then
				for i = 1, #fixed do out[i] = subst_pty(fixed[i], subst, bound) end
			end
			local va = x.vararg ~= nil and subst_pty(x.vararg, subst, bound) or nil
			return { fixed = out, vararg = va }
		end
		return { k = "fn", params = pr(p), ret = pr(r) }
	end
	if k == "rec" or k == "rec_with_indexer" then
		local fields = v.fields
		local fs = {} --[[: { [integer]: unknown } ]]
		if type(fields) == "table" then
			for i = 1, #fields do
				local f = fields[i]
				if type(f) == "table" then
					fs[i] = { key = f.key, ty = subst_pty(f.ty, subst, bound), optional = f.optional, readonly = f.readonly }
				end
			end
		end
		if k == "rec_with_indexer" then
			return { k = k, fields = fs, rows = v.rows, key = subst_pty(v.key, subst, bound), val = subst_pty(v.val, subst, bound) }
		end
		return { k = k, fields = fs, rows = v.rows }
	end
	if k == "indexer" then
		return { k = "indexer", key = subst_pty(v.key, subst, bound), val = subst_pty(v.val, subst, bound) }
	end
	if k == "union" or k == "inter" then
		local members = v.members
		local ms = {} --[[: { [integer]: unknown } ]]
		if type(members) == "table" then
			for i = 1, #members do ms[i] = subst_pty(members[i], subst, bound) end
		end
		return { k = k, members = ms }
	end
	-- primitives / literals: returned unchanged (already a fresh shallow copy not
	-- needed; the tree is treated as immutable data).
	return v
end

-- Apply σ (name -> PTy) to a generic-callee PTy, returning the interned Ty of the
-- monomorphic result, or nil if substitution or decode fails.
--: (unknown, { [string]: Ty }) -> Ty | nil
function M.apply_subst_pty(generic_pty, subst)
	-- encode σ's interned types to portable form for tree substitution.
	local psubst = {} --[[: { [string]: unknown } ]]
	for name, ty in pairs(subst) do psubst[name] = M.encode(ty) end
	local applied = subst_pty(generic_pty, psubst, {})
	return decode(applied, {})
end

-- ── Well-formedness: μ contractiveness + structural validity ─────────────────
--
-- A Ty produced by the decoder is structurally valid by construction (the
-- constructors interned it). The ONE obligation the decoder cannot enforce —
-- because it operates bottom-up through the interner — is μ CONTRACTIVENESS
-- (§9.3 finding 1): every occurrence of a μ's bound variable must be GUARDED
-- under a `rec` / `indexer` / `fn` constructor (a positive width). A μ whose
-- variable appears unguarded (e.g. `μX.(nil | X)`, `μX.never`) is ill-formed:
-- the cycle-guarded relation would read it as top, which is NOT what it denotes.
--
-- `contractive(ty)` walks the type; on entering a `mu` it checks that, within
-- its body, the binder's own variable never reaches an unguarded position. We
-- implement this via "is this μ's body contractive in the binder bound to depth
-- 1" — tracking de Bruijn depth, and flagging a `tyvar(idx)` that resolves to a
-- binder we have not yet crossed a guard for.

-- Walk `ty` checking that every μ in it is well-formed. A μ is well-formed iff
-- (a) every occurrence of its bound variable is GUARDED under a `rec`/`indexer`/
-- `fn` constructor (contractiveness), AND (b) the bound variable OCCURS at least
-- once in the body. Both conditions are necessary for the μ to denote what it is
-- meant to (§9.3 finding 1, §9.7 audit round 1 finding 1):
--   - non-contractive (`μX.(nil | X)`, `μX.X`) reads as TOP in the cycle-guarded
--     relation, not as its intended denotation;
--   - non-occurring (`μX.never`, `μX.number`) is a degenerate μ that denotes its
--     body verbatim (the unfold is a no-op substitution). It should have been
--     written as the body directly. We reject it as ill-formed rather than
--     silently accept a redundant binder — the principled resolution (the
--     interner cannot normalize it away because `mu_raw` interns before this
--     well-formedness pass runs; the gate is the right place to reject it).
--
-- `unguarded` = the number of enclosing μ binders that have NOT yet been guarded
-- since their binder (the innermost `unguarded` binders). A constructor
-- (`rec`/`indexer`/`fn`) resets `unguarded` to 0 for its children (everything
-- under it is guarded w.r.t. all currently-open binders). Entering a `mu` pushes
-- a new binder: it becomes unguarded (unguarded+1). A `tyvar(idx)` is
-- non-contractive iff `idx <= unguarded` (it refers to a binder not yet guarded
-- on this path).
--
-- Occurrence is tracked by an `occurs` accumulator keyed on de-Bruijn distance to
-- each open binder: `check_contractive` returns `(ok, saw_binder_1)` where
-- `saw_binder_1` reports whether the binder at de-Bruijn index 1 (relative to the
-- current point's binder count) occurred anywhere below. On entering a `mu` we
-- require that flag to be true.

-- check returns (well-formed-so-far, the de-Bruijn indices of binders that
-- occurred below). We represent the occurrence set as a function over indices via
-- a small table keyed on index. To keep it allocation-light we return a single
-- boolean for "did binder #1 (the nearest open binder) occur", shifting indices
-- as we cross binders. `occurred` accumulates, per open binder depth, whether it
-- was referenced.

local check_contractive --[[: (Ty, integer, { [integer]: boolean | nil }, integer) -> boolean ]]

-- `unguarded`: innermost binders not yet guarded on this path.
-- `occurred`: maps an ABSOLUTE binder depth (1 = outermost μ in the walk) to
--             whether its variable has been seen. `depth`: number of μ binders
--             currently open (so a tyvar at de-Bruijn idx `i` refers to absolute
--             binder `depth - i + 1`).
--: (Ty, integer, { [integer]: boolean | nil }, integer) -> boolean
check_contractive = function(ty, unguarded, occurred, depth)
	local k = ty.kind
	if k == "tyvar" then
		local idx = ty.idx or 1
		-- record the occurrence against the absolute binder this index refers to.
		local abs = depth - idx + 1
		if abs >= 1 then occurred[abs] = true end
		-- Refers to one of the innermost `unguarded` binders with no guard crossed.
		return idx > unguarded
	end
	if k == "mu" then
		local my_depth = depth + 1
		occurred[my_depth] = occurred[my_depth] or false
		if not check_contractive(ty.body or G.never(), unguarded + 1, occurred, my_depth) then
			return false
		end
		-- (b) the bound variable must occur at least once in the body.
		if not occurred[my_depth] then return false end
		occurred[my_depth] = nil
		return true
	end
	-- Guarding constructors: children are guarded w.r.t. all open binders.
	if k == "rec" or k == "rec_with_indexer" then
		local fields = ty.fields or {}
		for i = 1, #fields do
			if not check_contractive(fields[i].ty, 0, occurred, depth) then return false end
		end
		if k == "rec_with_indexer" then
			if not check_contractive(ty.key or G.never(), 0, occurred, depth) then return false end
			if not check_contractive(ty.val or G.never(), 0, occurred, depth) then return false end
		end
		return true
	end
	if k == "indexer" then
		if not check_contractive(ty.key or G.never(), 0, occurred, depth) then return false end
		if not check_contractive(ty.val or G.never(), 0, occurred, depth) then return false end
		return true
	end
	if k == "fn" then
		local p = ty.params or ({ fixed = {} } --[[: Params ]])
		local r = ty.ret or ({ fixed = {} } --[[: Ret ]])
		local pva = p.vararg --[[: Ty | nil ]]
		local rva = r.vararg --[[: Ty | nil ]]
		for i = 1, #p.fixed do if not check_contractive(p.fixed[i], 0, occurred, depth) then return false end end
		if pva ~= nil and not check_contractive(pva, 0, occurred, depth) then return false end
		for i = 1, #r.fixed do if not check_contractive(r.fixed[i], 0, occurred, depth) then return false end end
		if rva ~= nil and not check_contractive(rva, 0, occurred, depth) then return false end
		return true
	end
	-- Non-guarding connectives: pass `unguarded` through unchanged. A bound var
	-- as a bare union/inter member stays unguarded → flagged.
	if k == "union" or k == "inter" then
		local ms = ty.members or {}
		for i = 1, #ms do
			if not check_contractive(ms[i], unguarded, occurred, depth) then return false end
		end
		return true
	end
	-- Primitives / literals: no children, trivially contractive.
	return true
end

-- Public: is `ty` a well-formed slice type? (Decoded Ty assumed; checks
-- contractiveness of every μ.) Returns true/false.
--: (Ty) -> boolean
function M.well_formed(ty)
	return check_contractive(ty, 0, {}, 0)
end

return M
