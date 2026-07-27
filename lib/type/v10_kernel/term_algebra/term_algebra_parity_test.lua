-- lib/type/v10_kernel/term_algebra/term_algebra_parity_test.lua
--
-- Parity tests + parity fuzzing between the reference and fast tiers (repo
-- rule: multiple implementations of one spec require parity tests and
-- parity fuzzing — docs/conventions.md "Implementation tiers"). Uses
-- lib/test/fuzz.lua's corpus-mutation engine, replayable via FUZZ_SEED. The
-- byte input drives STRUCTURED term construction (each byte a construction
-- decision — pick an operator from the signature, pick a var index/sort,
-- recurse per the operator's declared arity/valence) so mutation walks the
-- term algebra itself (valid terms exercise the parity properties below;
-- mutated/truncated byte streams land on near-miss/malformed shapes that
-- exercise build's rejection paths) — not raw string-level mutation over
-- nothing.
--
-- TYPECHECKER WORKAROUND (tool-swap, not a code-level cast/rewrite — see
-- TODO.md for the full repro): the natural code for this file's generator
-- would have used lib/test/arb.lua (the properly-suited facility for
-- generating well-sorted ABTs respecting binder valence, with shrinking)
-- via a custom recursive `Arb` object fed through `arb.assert`/`arb.it`.
-- That path is blocked: `arb.assert`'s callback boundary is generically
-- typed `(...unknown) -> unknown`, and narrowing that `unknown` callback
-- parameter back to the generator's own concrete descriptor type has no
-- legal spelling in this checker — force casts are unconditionally
-- rejected ("force cast — fix the upstream type annotation instead"), and
-- checked casts FROM `unknown` are equally rejected (only genuine runtime
-- `type()`-narrowing is accepted, confirmed by minimal repro). Rather than
-- fully re-validate a self-generated value at every arb callback site (the
-- pattern shared.lua's declare_signature uses for genuinely external
-- data), this file drives its own typed generator from fuzz.lua's mutated
-- byte strings instead — `fn(input: string) -> unknown` types cleanly end
-- to end, and fuzz.lua's crash/seed-replay machinery (FUZZ_SEED) gives the
-- same reproducibility arb.lua's shrinking+PROP_SEED would have (minus
-- shrinking, not implemented for this recursive ADT either way). Revert to
-- arb.lua once `Arb`-callback narrowing has a legal path past `unknown`.
--
-- Also covers the ratified "cached context equals recomputed-from-scratch
-- context" property (docs/decisions/typechecker-v10-core-design.md's
-- follow-up ratification: "shift/subst must maintain the cached contexts
-- correctly — cover this explicitly ... fuzzing on its own").

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local fuzz = require("lib.test.fuzz")
local kernel = require("lib.type.v10_kernel.term_algebra")
local reference = require("lib.type.v10_kernel.term_algebra.reference")

local sig = kernel.declare_signature({
	name = "test-theory", version = 1, sorts = { "term" },
	ops = {
		zero = { result = "term", args = {} },
		succ = { result = "term", args = { { sort = "term" } } },
		app = { result = "term", args = { { sort = "term" }, { sort = "term" } } },
		lam = { result = "term", args = { { sort = "term", binds = { "term" } } } },
		pair2 = { result = "term", args = { { sort = "term", binds = { "term", "term" } } } },
	},
})

-- ── Byte-driven term descriptors ────────────────────────────────────────────
-- Plain Lua tables — not terms — so the SAME description can be built under
-- both tiers' independent kernel instances, guaranteeing structurally-
-- identical inputs to compare. A tagged union (like the kernel's own Term
-- type), not one flat record of optional fields.

--:: VarDesc = { k: "var", index: integer }
--:: MetaDesc = { k: "meta", id: string }
--:: ZeroDesc = { k: "zero" }
--:: SuccDesc = { k: "succ", a: Desc }
--:: AppDesc = { k: "app", a: Desc, b: Desc }
--:: LamDesc = { k: "lam", a: Desc }
--:: Pair2Desc = { k: "pair2", a: Desc }
--:: Desc = VarDesc | MetaDesc | ZeroDesc | SuccDesc | AppDesc | LamDesc | Pair2Desc

--:: ByteReader = { input: string, pos: integer }

--: (input: string) -> ByteReader
local function reader_new(input)
	return { input = input, pos = 1 }
end

-- Next byte, 0..255, cycling through the input (never blocks on an empty or
-- exhausted string — an empty input always yields 0).
--: (r: ByteReader) -> integer
local function reader_byte(r)
	if #r.input == 0 then return 0 end
	local b = r.input:byte(((r.pos - 1) % #r.input) + 1) or 0
	r.pos = r.pos + 1
	return b
end

--: (r: ByteReader, n: integer) -> integer
local function reader_mod(r, n)
	return reader_byte(r) % n
end

--: (r: ByteReader, depth: integer) -> Desc
local function gen_desc(r, depth)
	local leaf = depth <= 0
	local choice = leaf and reader_mod(r, 3) or reader_mod(r, 7)
	if choice == 0 then
		return { k = "var", index = reader_mod(r, 5) }
	elseif choice == 1 then
		return { k = "meta", id = "M" .. reader_mod(r, 3) }
	elseif choice == 2 then
		return { k = "zero" }
	elseif choice == 3 then
		return { k = "succ", a = gen_desc(r, depth - 1) }
	elseif choice == 4 then
		return { k = "app", a = gen_desc(r, depth - 1), b = gen_desc(r, depth - 1) }
	elseif choice == 5 then
		return { k = "lam", a = gen_desc(r, depth - 1) }
	else
		return { k = "pair2", a = gen_desc(r, depth - 1) }
	end
end

local MAX_DEPTH = 4

--: (input: string) -> Desc
local function desc_from_bytes(input)
	return gen_desc(reader_new(input), MAX_DEPTH)
end

--: (r: ByteReader, lo: integer, hi: integer) -> integer
local function reader_int(r, lo, hi)
	return lo + reader_mod(r, hi - lo + 1)
end

-- ── Term construction from a descriptor, under any kernel instance ─────────
--
-- TYPECHECKER WORKAROUND (see TODO.md for the full repro): the natural code
-- is a single top-level `build_from_desc(k, desc)` taking the kernel
-- instance as an explicit parameter and calling `k.build_var(...)` etc.
-- directly in its own body. That loses type information: a value's precise
-- inferred shape (from `local k = kernel.new(...)`) survives when its
-- MEMBERS are extracted (`local build_var = k.build_var`) at the point
-- where `k` is still a fresh, richly-typed local, and survives further when
-- those already-extracted FUNCTION values are passed as parameters into
-- another (even fully unannotated) function — but collapses to opaque
-- `unknown` the moment the TABLE `k` itself is passed as a function's own
-- parameter and member-accessed inside that function's body. Confirmed via
-- three minimal repros isolating each half. Worked around by extracting
-- `build_var`/`build_meta`/`build` at each call site (where `k_ref`/
-- `k_fast` are still fresh locals) and passing those three functions —
-- never `k` itself — into this factory. Revert to a single top-level
-- `build_from_desc(k, desc)` once this narrowing gap is fixed.
local function make_build_from_desc(build_var_fn, build_meta_fn, build_fn)
	--: (desc: Desc) -> (unknown | nil, string | nil)
	local function build(desc)
		if desc.k == "var" then
			return build_var_fn(desc.index, "term")
		elseif desc.k == "meta" then
			return build_meta_fn(desc.id, "term")
		elseif desc.k == "zero" then
			return build_fn(sig.ops.zero, {})
		elseif desc.k == "succ" then
			local a, err = build(desc.a)
			if not a then return nil, err end
			return build_fn(sig.ops.succ, { a })
		elseif desc.k == "app" then
			local a, aerr = build(desc.a)
			if not a then return nil, aerr end
			local b, berr = build(desc.b)
			if not b then return nil, berr end
			return build_fn(sig.ops.app, { a, b })
		elseif desc.k == "lam" then
			local a, err = build(desc.a)
			if not a then return nil, err end
			return build_fn(sig.ops.lam, { a })
		else -- pair2
			local a, err = build(desc.a)
			if not a then return nil, err end
			return build_fn(sig.ops.pair2, { a })
		end
	end
	return build
end

-- Both tiers expose the same field names on a FORCED (concrete) term
-- (var/meta/op — never a thunk); build/shift/instantiate always return
-- concrete terms in both tiers (only `subst` can return an unforced fast-
-- tier thunk — forced below via `k.shift(t, 0, 0)`, itself a primitive
-- operation, before any direct field inspection). A local re-statement of
-- the concrete-term shape (matching reference.lua's own Term type) so
-- inspection code below can narrow the otherwise-opaque `unknown` values
-- the kernel API returns.

--:: CtxMap = { [integer]: string }
--:: COpArgDecl = { sort: string, binds: string[], bound_count: integer }
--:: COpDecl = { name: string, sig_name: string, sig_version: integer, result: string, args: COpArgDecl[], arity: integer }
--:: CVar = { tag: "var", index: integer, sort: string, ctx: CtxMap, ground: boolean }
--:: CMeta = { tag: "meta", id: string, sort: string, ctx: CtxMap, ground: boolean }
--:: CArg = { bound_count: integer, term: ConcreteTerm }
--:: COp = { tag: "op", decl: COpDecl, args: CArg[], sort: string, ctx: CtxMap, ground: boolean }
--:: ConcreteTerm = CVar | CMeta | COp

-- The kernel API's return values are opaque (`unknown`) at this module
-- boundary, and this checker rejects both force casts and checked casts
-- FROM `unknown` (only genuine runtime `type()`-narrowing is accepted —
-- confirmed via minimal repro, same rule shared.lua's declare_signature
-- relies on for validating external data). `as_concrete` is that same
-- narrowing pattern applied to the kernel's own (self-generated, already
-- well-formed) term values: it re-validates and rebuilds a properly-typed
-- ConcreteTerm from an opaque result, once, at the point each primitive's
-- output needs field-level inspection below.
--: (ctx_: unknown) -> CtxMap
local function as_ctx(ctx_)
	if type(ctx_) ~= "table" then error("term ctx is not a table") end
	local raw = ctx_ --[[: { [unknown]: unknown } ]]
	local out = {} --[[: CtxMap ]]
	for idx, s in pairs(raw) do
		if type(idx) ~= "number" then error("ctx key is not a number") end
		if type(s) ~= "string" then error("ctx value is not a string") end
		out[idx] = s
	end
	return out
end

-- Narrow, NOT rebuild: decl objects are operator identities (ratified —
-- "operator identity = declared-object identity"); reference.equal's
-- op-comparison checks `a.decl == b.decl` by Lua table pointer identity.
-- Reconstructing a fresh decl table here (as as_concrete does for the
-- surrounding term) would silently break that identity check for every op
-- node, so this is a type-only narrowing cast (checked, not force — a
-- generic `table`, established by the type() check, casts cleanly to a
-- specific record; only `unknown` itself cannot) that returns the SAME
-- object, never copies it.
--: (d: unknown) -> COpDecl
local function as_decl(d)
	if type(d) ~= "table" then error("decl is not a table") end
	return d --[[: COpDecl ]]
end

--: (t: unknown) -> ConcreteTerm
local function as_concrete(t)
	if type(t) ~= "table" then error("term is not a table") end
	local raw = t --[[: { [string]: unknown } ]]
	local tag = raw.tag
	local sort = raw.sort
	local ground = raw.ground
	if type(sort) ~= "string" then error("term sort is not a string") end
	if type(ground) ~= "boolean" then error("term ground is not a boolean") end
	local ctx = as_ctx(raw.ctx)
	if tag == "var" then
		local index_raw = raw.index
		if type(index_raw) ~= "number" then error("var index is not a number") end
		return { tag = "var", index = math.floor(index_raw), sort = sort, ctx = ctx, ground = ground }
	elseif tag == "meta" then
		local id = raw.id
		if type(id) ~= "string" then error("meta id is not a string") end
		return { tag = "meta", id = id, sort = sort, ctx = ctx, ground = ground }
	elseif tag == "op" then
		local args_raw = raw.args
		if type(args_raw) ~= "table" then error("op args is not a table") end
		local args_arr = args_raw --[[: unknown[] ]]
		local out_args = {} --[[: CArg[] ]]
		local i = 0
		for _, a_ in ipairs(args_arr) do
			i = i + 1
			if type(a_) ~= "table" then error("op arg is not a table") end
			local a = a_ --[[: { [string]: unknown } ]]
			local bound_count_raw = a.bound_count
			if type(bound_count_raw) ~= "number" then error("op arg bound_count is not a number") end
			out_args[i] = { bound_count = math.floor(bound_count_raw), term = as_concrete(a.term) }
		end
		return { tag = "op", decl = as_decl(raw.decl), args = out_args, sort = sort, ctx = ctx, ground = ground }
	end
	error("unrecognized term tag: " .. tostring(tag))
end

-- TYPECHECKER WORKAROUND: same self-recursive return-narrowing gap as
-- fast.lua's force_head (see TODO.md) — recompute_ctx's own recursive
-- self-call loses its declared CtxMap return type once assigned to a local
-- and iterated. Worked around identically: a checked cast restating the
-- function's own already-declared return type.
--: (t: ConcreteTerm) -> CtxMap
local function recompute_ctx(t)
	if t.tag == "var" then
		return { [t.index] = t.sort }
	elseif t.tag == "meta" then
		return {}
	elseif t.tag == "op" then
		local merged = {} --[[: CtxMap ]]
		local args = t.args
		for _, a in ipairs(args) do
			local bound_count = a.bound_count
			local sub = recompute_ctx(a.term) --[[: CtxMap ]]
			for idx, s in pairs(sub) do
				if idx >= bound_count then merged[idx - bound_count] = s end
			end
		end
		return merged
	end
	error("unrecognized term tag")
end

--: (a: CtxMap, b: CtxMap) -> boolean
local function ctx_equal(a, b)
	for idx, s in pairs(a) do if b[idx] ~= s then return false end end
	for idx, s in pairs(b) do if a[idx] ~= s then return false end end
	return true
end

-- Force a possibly-unforced (fast tier) term to concrete form using only a
-- primitive already in the ratified set: shift by 0 at cutoff 0 always
-- forces-and-rebuilds structurally in both tiers (a no-op value-wise).
-- Same extract-then-pass-the-function workaround as make_build_from_desc
-- above: takes the already-extracted `shift` function, never the kernel
-- instance table itself.
local function make_forcer(shift_fn)
	--: (t: unknown) -> ConcreteTerm
	local function force(t)
		return as_concrete(shift_fn(t, 0, 0))
	end
	return force
end

local FUZZ_OPTS = { iters = 300, seeds = { "", "\0", "\1\2\3\4\5\6\7" } }

-- ── Parity: build ────────────────────────────────────────────────────────

fuzz.it("parity: build agrees across tiers (success/failure and structure)", function(input)
	local desc = desc_from_bytes(input)
	local k_ref = kernel.new({ tier = "reference" })
	local k_fast = kernel.new({ tier = "fast" })
	local build_ref = make_build_from_desc(k_ref.build_var, k_ref.build_meta, k_ref.build)
	local build_fast = make_build_from_desc(k_fast.build_var, k_fast.build_meta, k_fast.build)
	local t_ref, e_ref = build_ref(desc)
	local t_fast, e_fast = build_fast(desc)
	if (t_ref == nil) ~= (t_fast == nil) then
		error("tiers disagree on build success: ref_ok=" .. tostring(t_ref ~= nil)
			.. " fast_ok=" .. tostring(t_fast ~= nil) .. " ref_err=" .. tostring(e_ref) .. " fast_err=" .. tostring(e_fast))
	end
	if t_ref then
		local tr = as_concrete(t_ref)
		local tf = as_concrete(t_fast)
		if not reference.equal(tr, tf) then error("built terms differ structurally") end
		if k_ref.sort_of(tr) ~= k_fast.sort_of(tf) then error("sort_of differs") end
		if k_ref.is_ground(tr) ~= k_fast.is_ground(tf) then error("is_ground differs") end
		if k_ref.is_closed(tr) ~= k_fast.is_closed(tf) then error("is_closed differs") end
	end
end, FUZZ_OPTS)

-- ── Parity: equal ────────────────────────────────────────────────────────

fuzz.it("parity: equal agrees across tiers", function(input)
	local r = reader_new(input)
	local desc_a = gen_desc(r, MAX_DEPTH)
	local desc_b = gen_desc(r, MAX_DEPTH)
	local k_ref = kernel.new({ tier = "reference" })
	local k_fast = kernel.new({ tier = "fast" })
	local build_ref = make_build_from_desc(k_ref.build_var, k_ref.build_meta, k_ref.build)
	local build_fast = make_build_from_desc(k_fast.build_var, k_fast.build_meta, k_fast.build)
	local a_ref = build_ref(desc_a)
	local b_ref = build_ref(desc_b)
	local a_fast = build_fast(desc_a)
	local b_fast = build_fast(desc_b)
	if not (a_ref and b_ref and a_fast and b_fast) then return end -- ill-sorted per this run; skip
	local eq_ref = k_ref.equal(a_ref, b_ref)
	local eq_fast = k_fast.equal(a_fast, b_fast)
	if eq_ref ~= eq_fast then
		error("equal disagreement: ref=" .. tostring(eq_ref) .. " fast=" .. tostring(eq_fast))
	end
end, FUZZ_OPTS)

-- ── Parity: shift ────────────────────────────────────────────────────────

fuzz.it("parity: shift agrees across tiers", function(input)
	local r = reader_new(input)
	local desc = gen_desc(r, MAX_DEPTH)
	local d = reader_int(r, -3, 3)
	local cutoff = reader_int(r, 0, 4)
	local k_ref = kernel.new({ tier = "reference" })
	local k_fast = kernel.new({ tier = "fast" })
	local build_ref = make_build_from_desc(k_ref.build_var, k_ref.build_meta, k_ref.build)
	local build_fast = make_build_from_desc(k_fast.build_var, k_fast.build_meta, k_fast.build)
	local t_ref = build_ref(desc)
	local t_fast = build_fast(desc)
	if not (t_ref and t_fast) then return end
	local s_ref, e_ref = k_ref.shift(t_ref, d, cutoff)
	local s_fast, e_fast = k_fast.shift(t_fast, d, cutoff)
	if (s_ref == nil) ~= (s_fast == nil) then
		error("tiers disagree on shift success: ref_err=" .. tostring(e_ref) .. " fast_err=" .. tostring(e_fast))
	end
	if s_ref then
		local sr = as_concrete(s_ref)
		local sf = as_concrete(s_fast)
		if not reference.equal(sr, sf) then error("shifted terms differ structurally") end
	end
end, FUZZ_OPTS)

-- ── Parity: subst ────────────────────────────────────────────────────────

fuzz.it("parity: subst agrees across tiers", function(input)
	local r = reader_new(input)
	local desc = gen_desc(r, MAX_DEPTH)
	local idx = reader_int(r, 0, 3)
	local u_desc = gen_desc(r, MAX_DEPTH)
	local k_ref = kernel.new({ tier = "reference" })
	local k_fast = kernel.new({ tier = "fast" })
	local build_ref = make_build_from_desc(k_ref.build_var, k_ref.build_meta, k_ref.build)
	local build_fast = make_build_from_desc(k_fast.build_var, k_fast.build_meta, k_fast.build)
	local force_fast = make_forcer(k_fast.shift)
	local t_ref = build_ref(desc)
	local u_ref = build_ref(u_desc)
	local t_fast = build_fast(desc)
	local u_fast = build_fast(u_desc)
	if not (t_ref and u_ref and t_fast and u_fast) then return end
	local s_ref, e_ref = k_ref.subst(t_ref, idx, u_ref)
	local s_fast, e_fast = k_fast.subst(t_fast, idx, u_fast)
	if (s_ref == nil) ~= (s_fast == nil) then
		error("tiers disagree on subst success: ref_err=" .. tostring(e_ref) .. " fast_err=" .. tostring(e_fast))
	end
	if s_ref then
		local sr = as_concrete(s_ref)
		local s_fast_forced = force_fast(s_fast)
		if not reference.equal(sr, s_fast_forced) then
			error("substituted terms differ structurally")
		end
	end
end, FUZZ_OPTS)

-- ── Parity: match + instantiate round trip ─────────────────────────────────

fuzz.it("parity: match agrees across tiers (success/failure and bindings)", function(input)
	local r = reader_new(input)
	local pat_desc = gen_desc(r, MAX_DEPTH)
	local term_desc = gen_desc(r, MAX_DEPTH)
	local k_ref = kernel.new({ tier = "reference" })
	local k_fast = kernel.new({ tier = "fast" })
	local build_ref = make_build_from_desc(k_ref.build_var, k_ref.build_meta, k_ref.build)
	local build_fast = make_build_from_desc(k_fast.build_var, k_fast.build_meta, k_fast.build)
	local p_ref = build_ref(pat_desc)
	local t_ref = build_ref(term_desc)
	local p_fast = build_fast(pat_desc)
	local t_fast = build_fast(term_desc)
	if not (p_ref and t_ref and p_fast and t_fast) then return end
	local b_ref, e_ref = k_ref.match(p_ref, t_ref)
	local b_fast, e_fast = k_fast.match(p_fast, t_fast)
	if (b_ref == nil) ~= (b_fast == nil) then
		error("tiers disagree on match success: ref_err=" .. tostring(e_ref) .. " fast_err=" .. tostring(e_fast))
	end
	if b_ref then
		local bindings_ref = b_ref --[[: { [string]: { term: ConcreteTerm, depth: integer } } ]]
		local bindings_fast = b_fast --[[: { [string]: { term: ConcreteTerm, depth: integer } } ]]
		for id, binding in pairs(bindings_ref) do
			local fb = bindings_fast[id]
			if not fb then error("fast tier missing binding for " .. id) end
			if binding.depth ~= fb.depth then error("binding depth differs for " .. id) end
			if not reference.equal(binding.term, fb.term) then error("binding term differs for " .. id) end
		end
		for id in pairs(bindings_fast) do
			if not bindings_ref[id] then error("fast tier has extra binding for " .. id) end
		end

		-- instantiate round trip must also agree.
		local i_ref, ierr1 = k_ref.instantiate(p_ref, b_ref)
		local i_fast, ierr2 = k_fast.instantiate(p_fast, b_fast)
		if (i_ref == nil) ~= (i_fast == nil) then
			error("tiers disagree on instantiate success: " .. tostring(ierr1) .. " / " .. tostring(ierr2))
		end
		if i_ref then
			local ir = as_concrete(i_ref)
			local iff = as_concrete(i_fast)
			if not reference.equal(ir, iff) then error("instantiated terms differ structurally") end
		end
	end
end, FUZZ_OPTS)

-- ── Context-cache correctness (both tiers) ──────────────────────────────────
-- Ratified follow-up: "shift/subst must maintain the cached contexts
-- correctly ... e.g. property 'cached context equals recomputed-from-
-- scratch context' on arbitrary terms."

for _, tier in ipairs({ "reference", "fast" }) do
	fuzz.it("context cache correctness (" .. tier .. "): cached ctx == recomputed ctx, after build", function(input)
		local desc = desc_from_bytes(input)
		local k = kernel.new({ tier = tier })
		local build = make_build_from_desc(k.build_var, k.build_meta, k.build)
		local do_force = make_forcer(k.shift)
		local t = build(desc)
		if not t then return end
		local ft = do_force(t)
		if not ctx_equal(ft.ctx, recompute_ctx(ft)) then
			error("cached ctx does not match recomputed ctx")
		end
	end, FUZZ_OPTS)

	fuzz.it("context cache correctness (" .. tier .. "): cached ctx == recomputed ctx, after shift", function(input)
		local r = reader_new(input)
		local desc = gen_desc(r, MAX_DEPTH)
		local d = reader_int(r, -3, 3)
		local cutoff = reader_int(r, 0, 4)
		local k = kernel.new({ tier = tier })
		local build = make_build_from_desc(k.build_var, k.build_meta, k.build)
		local do_force = make_forcer(k.shift)
		local t = build(desc)
		if not t then return end
		local s = k.shift(t, d, cutoff)
		if not s then return end
		local fs = do_force(s)
		if not ctx_equal(fs.ctx, recompute_ctx(fs)) then
			error("cached ctx does not match recomputed ctx after shift")
		end
	end, FUZZ_OPTS)

	fuzz.it("context cache correctness (" .. tier .. "): cached ctx == recomputed ctx, after subst", function(input)
		local r = reader_new(input)
		local desc = gen_desc(r, MAX_DEPTH)
		local idx = reader_int(r, 0, 3)
		local u_desc = gen_desc(r, MAX_DEPTH)
		local k = kernel.new({ tier = tier })
		local build = make_build_from_desc(k.build_var, k.build_meta, k.build)
		local do_force = make_forcer(k.shift)
		local t = build(desc)
		local u = build(u_desc)
		if not (t and u) then return end
		local s = k.subst(t, idx, u)
		if not s then return end
		local fs = do_force(s)
		if not ctx_equal(fs.ctx, recompute_ctx(fs)) then
			error("cached ctx does not match recomputed ctx after subst")
		end
	end, FUZZ_OPTS)
end

return {}
