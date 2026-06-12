-- lib/type/analysis/slice_subtype_test.lua
--
-- Pass-1 tests for the `crescent.slice.v1` Ty grammar + hash-cons interner +
-- subtype relation (docs/agnostic-static-analysis-crescent-slice.md §3, §3.5).
--
-- Three groups:
--   1. interner identity (hash-consing, mu alpha-equivalence, unfold);
--   2. subtype unit tests — every rule family + the §6.2 worked μ example;
--   3. seeded property/fuzz invariants (§3.5): reflexivity, unknown/never laws,
--      transitivity sampling, μ-unfolding equivalence, union/inter lattice laws,
--      termination-under-fuzz. Seed is fixed for replay (override with FUZZ_SEED).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local gen = require("lib.test.gen")
local G   = require("lib.type.analysis.slice_ty")
local S   = require("lib.type.analysis.slice_subtype")

-- `Ty`, `Field`, `Rows` are the grammar aliases declared in slice_ty.lua and made
-- visible here by requiring it (the same cross-module-alias visibility stlc_test
-- relies on for `StTerm`). The module value is `G`, so the `Ty` type name is free.
--:: Rng = { seed: number, next: (self: Rng) -> number, float: (self: Rng) -> number, int: (self: Rng, lo: integer, hi: integer) -> integer, bool: (self: Rng) -> boolean, pick: <T>(self: Rng, t: T[]) -> T }

-- Field constructor shorthand. Return type is inferred (the structural field
-- shape) so it unifies with the `G.rec`/`G.rec_with_indexer` field parameter
-- across the module boundary without an alias-identity mismatch.
-- Generic so `T` infers to slice_ty's actual `Ty` (a NAMED cross-module alias
-- as the param type would create a fresh non-unifying copy; inference preserves
-- identity).
--: <T>(string, T, boolean | nil) -> { key: string, ty: T, optional: boolean, readonly: boolean }
local function fld(k, t, opt)
	return { key = k, ty = t, optional = opt or false, readonly = false }
end

-- ── 1. Interner identity ─────────────────────────────────────────────────────

T.describe("slice_ty interner", function()
	G.reset()

	T.it("primitives are singletons", function()
		T.eq(G.integer().tid, G.integer().tid, "integer interns once")
		T.neq(G.integer().tid, G.number().tid, "integer ≠ number")
		T.neq(G.unknown().tid, G.never().tid, "unknown ≠ never")
	end)

	T.it("literals intern by value", function()
		T.eq(G.lit_str("GET").tid, G.lit_str("GET").tid, "same string literal shares tid")
		T.neq(G.lit_str("GET").tid, G.lit_str("POST").tid, "distinct string literals differ")
		T.eq(G.lit_int(42).tid, G.lit_int(42).tid, "same int literal shares tid")
		T.neq(G.lit_int(42).tid, G.lit_int(43).tid, "distinct int literals differ")
	end)

	T.it("union is order-insensitive and flattening", function()
		local u1 = G.union({ G.integer(), G.nil_() })
		local u2 = G.union({ G.nil_(), G.integer() })
		T.eq(u1.tid, u2.tid, "union member order does not affect identity")
		local nested = G.union({ u1, G.string() })
		local flat   = G.union({ G.integer(), G.nil_(), G.string() })
		T.eq(nested.tid, flat.tid, "union of unions flattens")
	end)

	T.it("union/inter normalization laws", function()
		T.eq(G.union({}).tid, G.never().tid, "union([]) = never")
		T.eq(G.union({ G.never(), G.integer() }).tid, G.integer().tid, "never absorbed in union")
		T.eq(G.union({ G.unknown(), G.integer() }).kind, "unknown", "unknown absorbs union")
		T.eq(G.union({ G.integer() }).tid, G.integer().tid, "singleton union = member")
		T.eq(G.inter({}).kind, "unknown", "inter([]) = unknown")
		T.eq(G.inter({ G.unknown(), G.integer() }).tid, G.integer().tid, "unknown dropped in inter")
		T.eq(G.inter({ G.never(), G.integer() }).tid, G.never().tid, "never absorbs inter")
	end)

	T.it("records intern key-insensitively to field order", function()
		local r1 = G.rec({ fld("a", G.integer()), fld("b", G.string()) }, "closed")
		local r2 = G.rec({ fld("b", G.string()), fld("a", G.integer()) }, "closed")
		T.eq(r1.tid, r2.tid, "field order does not affect record identity")
		local r3 = G.rec({ fld("a", G.integer()), fld("b", G.string()) }, "open")
		T.neq(r1.tid, r3.tid, "open vs closed rows are distinct records")
	end)

	T.it("mu is alpha-equivalent under hash-consing", function()
		local m1 = G.mu("X", function(x)
			return G.union({ G.nil_(), G.rec({ fld("next", x) }, "closed") })
		end)
		local m2 = G.mu("Y", function(y)
			return G.union({ G.nil_(), G.rec({ fld("next", y) }, "closed") })
		end)
		T.eq(m1.tid, m2.tid, "μ types equal up to bound-variable name share a tid")
	end)

	T.it("unfold reinserts the mu at the recursive position", function()
		local m = G.mu("X", function(x)
			return G.union({ G.nil_(), G.rec({ fld("next", x) }, "closed") })
		end)
		local u = G.unfold(m)
		T.eq(u.kind, "union", "unfold of μ(...|rec) is the union")
		-- the rec member's `next` field points back at the whole μ.
		local members = u.members or {}
		local rec_member --[[: Ty ]] = members[1]
		if rec_member.kind ~= "rec" then rec_member = members[2] end
		local rfields = rec_member.fields or {} --[[: Field[] ]]
		local first_field = rfields[1] --[[: Field ]]
		local next_ty = first_field.ty --: Ty
		T.eq(next_ty.tid, m.tid, "recursive occurrence unfolds to the μ itself")
	end)

	T.it("nested mu builds idempotently", function()
		--: (string, string) -> Ty
		local function build(x_name, y_name)
			return G.mu(x_name, function(x)
				return G.rec({
					fld("self", x),
					fld("inner", G.mu(y_name, function(y)
						return G.union({ G.nil_(), G.rec({ fld("p", x), fld("q", y) }, "closed") })
					end)),
				}, "closed")
			end)
		end
		T.eq(build("X", "Y").tid, build("Z", "W").tid, "nested μ with cross-binder refs is alpha-canonical")
	end)
end)

-- ── 2. Subtype unit tests — per rule family ──────────────────────────────────

T.describe("slice_subtype rules", function()
	G.reset()

	T.it("top and bottom laws", function()
		T.ok(S.is_subtype(G.string(), G.unknown()), "T <: unknown")
		T.ok(S.is_subtype(G.never(), G.string()), "never <: T")
		T.ok(S.is_subtype(G.unknown(), G.unknown()), "unknown <: unknown")
		T.ok(S.is_subtype(G.never(), G.never()), "never <: never")
		T.fail(S.is_subtype(G.unknown(), G.string()), "unknown </: a non-top")
		T.fail(S.is_subtype(G.string(), G.never()), "non-bottom </: never")
	end)

	T.it("primitives and integer <: number", function()
		T.ok(S.is_subtype(G.integer(), G.number()), "integer <: number")
		T.fail(S.is_subtype(G.number(), G.integer()), "number </: integer")
		T.ok(S.is_subtype(G.string(), G.string()), "string <: string (refl)")
		T.fail(S.is_subtype(G.string(), G.number()), "string </: number")
		T.fail(S.is_subtype(G.boolean(), G.number()), "boolean </: number")
	end)

	T.it("literal singletons against their bases", function()
		T.ok(S.is_subtype(G.lit_int(42), G.integer()), "42 <: integer")
		T.ok(S.is_subtype(G.lit_int(42), G.number()), "42 <: number")
		T.ok(S.is_subtype(G.lit_str("GET"), G.string()), "\"GET\" <: string")
		T.ok(S.is_subtype(G.lit_bool(true), G.boolean()), "true <: boolean")
		T.ok(S.is_subtype(G.lit_num(3.5), G.number()), "3.5 <: number")
		T.fail(S.is_subtype(G.string(), G.lit_str("GET")), "base </: its literal")
		T.fail(S.is_subtype(G.lit_int(42), G.lit_int(43)), "distinct int literals incomparable")
		T.fail(S.is_subtype(G.lit_num(3.5), G.integer()), "non-integer literal </: integer")
	end)

	T.it("union rules (left every, right some)", function()
		local A, B, C = G.integer(), G.string(), G.boolean()
		T.ok(S.is_subtype(A, G.union({ A, B })), "A <: A | B")
		T.ok(S.is_subtype(G.union({ A, B }), G.union({ A, B, C })), "A|B <: A|B|C")
		T.fail(S.is_subtype(G.union({ A, B }), A), "A|B </: A")
		T.ok(S.is_subtype(G.lit_int(1), G.union({ G.string(), G.number() })), "1 <: string|number via number")
	end)

	T.it("intersection rules (left some, right every)", function()
		local A, B = G.integer(), G.string()
		T.ok(S.is_subtype(G.inter({ A, B }), A), "A&B <: A")
		T.ok(S.is_subtype(G.lit_int(5), G.inter({ G.integer(), G.number() })), "5 <: int & number")
		T.fail(S.is_subtype(A, G.inter({ A, B })), "A </: A & B")
	end)

	T.it("function contra/covariance, multi-return, vararg", function()
		local f_num_int = G.fn({ fixed = { G.number() } }, { fixed = { G.integer() } })
		local f_int_num = G.fn({ fixed = { G.integer() } }, { fixed = { G.number() } })
		T.ok(S.is_subtype(f_num_int, f_int_num), "(number)->integer <: (integer)->number")
		T.fail(S.is_subtype(f_int_num, f_num_int), "(integer)->number </: (number)->integer")
		T.ok(S.is_subtype(f_num_int, G.func()), "specific fn <: function top")
		-- multi-return: longer return tuple <: shorter prefix (extra returns droppable).
		local f_ab = G.fn({ fixed = {} }, { fixed = { G.integer(), G.string() } })
		local f_a  = G.fn({ fixed = {} }, { fixed = { G.integer() } })
		T.ok(S.is_subtype(f_ab, f_a), "() -> (int, str) <: () -> (int)")
		T.fail(S.is_subtype(f_a, f_ab), "() -> (int) </: () -> (int, str)")
		-- vararg spread: a vararg callee accepts the extra fixed params.
		local f_var = G.fn({ fixed = {}, vararg = G.number() }, { fixed = {} })
		local f_one = G.fn({ fixed = { G.integer() } }, { fixed = {} })
		T.ok(S.is_subtype(f_var, f_one), "(...number)->() <: (integer)->() (vararg covers fixed)")
	end)

	T.it("record width, depth, optional", function()
		local r_ab = G.rec({ fld("a", G.integer()), fld("b", G.string()) }, "closed")
		local r_a  = G.rec({ fld("a", G.number()) }, "closed")
		T.ok(S.is_subtype(r_ab, r_a), "{a:int,b:str} <: {a:num} (width + depth)")
		T.fail(S.is_subtype(r_a, r_ab), "{a:num} </: {a:int,b:str} (missing field)")
		-- optional field on B may be absent in A.
		local r_a_optb = G.rec({ fld("a", G.integer()), fld("b", G.string(), true) }, "closed")
		T.ok(S.is_subtype(G.rec({ fld("a", G.integer()) }, "closed"), r_a_optb), "absent optional field OK")
		-- depth covariance.
		T.ok(S.is_subtype(G.rec({ fld("a", G.lit_int(1)) }, "closed"), G.rec({ fld("a", G.integer()) }, "closed")), "field depth covariant")
	end)

	T.it("open-row rules and the ...-vs-indexer distinction", function()
		local open_named = G.rec({ fld("name", G.string()) }, "open")
		local closed_named = G.rec({ fld("name", G.string()) }, "closed")
		-- open B accepts any A satisfying the named fields.
		T.ok(S.is_subtype(closed_named, open_named), "closed {name} <: open {name,...}")
		-- open A is NOT <: a closed B (the open tail could violate closedness).
		T.fail(S.is_subtype(open_named, closed_named), "open {name,...} </: closed {name}")
		-- THE hard distinction: open row ≠ index signature.
		local idx = G.indexer(G.string(), G.unknown())
		T.fail(S.is_subtype(open_named, idx), "{name:str,...} </: {[str]:unknown} (open ≠ indexer)")
	end)

	T.it("indexer contravariant key, covariant value", function()
		local i_str_int = G.indexer(G.string(), G.integer())
		local i_str_num = G.indexer(G.string(), G.number())
		T.ok(S.is_subtype(i_str_int, i_str_num), "{[str]:int} <: {[str]:num} (value covariant)")
		T.fail(S.is_subtype(i_str_num, i_str_int), "{[str]:num} </: {[str]:int}")
		-- a closed tuple-shaped rec <: indexer(integer, V) iff every field <: V.
		local tup = G.rec({ fld("1", G.lit_int(1)), fld("2", G.lit_int(2)) }, "closed")
		-- (keys are integer-literal strings here only nominally; subtype uses the key
		--  string as a singleton, so use string-keyed index for this structural check)
		local sidx = G.indexer(G.string(), G.number())
		T.ok(S.is_subtype(tup, sidx), "closed rec with number fields <: {[str]:num}")
	end)

	T.it("rec_with_indexer decomposes to rec part and indexer part", function()
		local rwi = G.rec_with_indexer({ fld("tag", G.string()) }, "closed", { key = G.string(), val = G.number() })
		-- a record providing tag:str and a number-valued field satisfies it.
		local a = G.rec_with_indexer({ fld("tag", G.string()) }, "closed", { key = G.string(), val = G.integer() })
		T.ok(S.is_subtype(a, rwi), "rwi value-covariant indexer refinement")
	end)

	T.it("§6.2 worked example — HamtNode μ subtyping without stack overflow", function()
		local HamtNode = G.mu("X", function(x)
			local Leaf     = G.rec({ fld("kind", G.integer()), fld("key", G.unknown()) }, "closed")
			local Interior = G.rec({ fld("kind", G.integer()), fld("children", G.indexer(G.integer(), x)) }, "closed")
			return G.union({ Leaf, Interior })
		end)
		T.ok(S.is_subtype(HamtNode, HamtNode), "HamtNode <: HamtNode (reflexivity by interning)")
		T.ok(S.is_subtype(HamtNode, G.unfold(HamtNode)), "μ <: its one-step unfold")
		T.ok(S.is_subtype(G.unfold(HamtNode), HamtNode), "unfold <: μ (equirecursive)")
		local Interior = G.rec({ fld("kind", G.integer()), fld("children", G.indexer(G.integer(), HamtNode)) }, "closed")
		T.ok(S.is_subtype(Interior, HamtNode), "Interior(HamtNode) <: HamtNode (coinductive)")
	end)

	T.it("witness variant returns a counterexample on rejection", function()
		local ok, ce = S.subtype(G.string(), G.integer())
		T.fail(ok, "string </: integer")
		T.ok(ce ~= nil, "counterexample present on rejection")
		T.eq(ce and ce.kind, "not_subtype", "counterexample names the failure kind")
		local ok2, ce2 = S.subtype(G.integer(), G.number())
		T.ok(ok2, "integer <: number accepted")
		T.eq(ce2, nil, "no counterexample on acceptance")
	end)
end)

-- ── 3. Seeded property/fuzz invariants (§3.5) ────────────────────────────────
--
-- A bounded-depth Ty generator over a fresh interner, plus the §3.5 invariants.
-- Seed is fixed for replay; override with FUZZ_SEED. Every generated query runs
-- under the harness; a hang would blow the timeout-30 ceiling (termination law).

local FUZZ_SEED = tonumber(os.getenv("FUZZ_SEED") or "") or 0xC0FFEE
local FUZZ_N    = tonumber(os.getenv("FUZZ_N") or "") or 400

-- Leaf (non-recursive) types for the generator.
--: (Rng) -> Ty
local function gen_leaf(rng)
	local pick = rng:int(1, 12)
	if pick == 1 then return G.nil_() end
	if pick == 2 then return G.boolean() end
	if pick == 3 then return G.number() end
	if pick == 4 then return G.integer() end
	if pick == 5 then return G.string() end
	if pick == 6 then return G.func() end
	if pick == 7 then return G.unknown() end
	if pick == 8 then return G.never() end
	if pick == 9 then return G.lit_int(rng:int(0, 3)) end
	if pick == 10 then return G.lit_str(rng:pick({ "GET", "POST", "x" } --[[: string[] ]])) end
	if pick == 11 then return G.lit_bool(rng:bool()) end
	return G.integer()
end

-- A bounded-depth Ty generator. `depth` budgets recursion; `tv` is the in-scope
-- μ-bound variable (or nil), so generated μ bodies can reference it.
--: (Rng, integer, Ty | nil) -> Ty
local function gen_ty(rng, depth, tv)
	if depth <= 0 then
		if tv ~= nil and rng:int(1, 4) == 1 then return tv end
		return gen_leaf(rng)
	end
	local pick = rng:int(1, 10)
	if pick <= 3 then
		return gen_leaf(rng)
	elseif pick == 4 and tv ~= nil then
		return tv
	elseif pick == 5 then
		-- union of 2-3 members
		local n = rng:int(2, 3)
		local ms = {} --[[: { [integer]: Ty } ]]
		for _ = 1, n do ms[#ms + 1] = gen_ty(rng, depth - 1, tv) end
		return G.union(ms)
	elseif pick == 6 then
		local n = rng:int(2, 3)
		local ms = {} --[[: { [integer]: Ty } ]]
		for _ = 1, n do ms[#ms + 1] = gen_ty(rng, depth - 1, tv) end
		return G.inter(ms)
	elseif pick == 7 then
		-- record (nf ∈ {0,1,2} fields, each generated)
		local nf = rng:int(0, 2)
		if nf == 0 then return G.rec({}, rng:int(1, 3) == 1 and "open" or "closed") end
		if nf == 1 then
			return G.rec({ fld("f1", gen_ty(rng, depth - 1, tv), rng:int(1, 4) == 1) },
				rng:int(1, 3) == 1 and "open" or "closed")
		end
		return G.rec({
			fld("f1", gen_ty(rng, depth - 1, tv), rng:int(1, 4) == 1),
			fld("f2", gen_ty(rng, depth - 1, tv), rng:int(1, 4) == 1),
		}, rng:int(1, 3) == 1 and "open" or "closed")
	elseif pick == 8 then
		return G.indexer(rng:bool() and G.string() or G.integer(), gen_ty(rng, depth - 1, tv))
	elseif pick == 9 then
		-- function
		local np = rng:int(0, 2)
		local fixed = {} --[[: { [integer]: Ty } ]]
		for _ = 1, np do fixed[#fixed + 1] = gen_ty(rng, depth - 1, tv) end
		return G.fn({ fixed = fixed }, { fixed = { gen_ty(rng, depth - 1, tv) } })
	else
		-- μ (only when no μ var already in scope, to keep bodies simple/closed).
		-- The body is ALWAYS a union whose first arm is a non-recursive leaf, so the
		-- generated μ is well-formed per §3.3 ("every μ has a non-recursive arm").
		-- A degenerate `μX.X` (no base case) is outside the slice grammar; emitting
		-- it would make the relation's coinductive hypothesis treat it as top, which
		-- is meaningless rather than a relation bug.
		if tv ~= nil then return gen_leaf(rng) end
		-- Well-formed equirecursive μ (§3.3): the body is a union of a concrete
		-- base arm (a non-`never`/`unknown` primitive, so normalization can't drop
		-- it) and a recursive arm where the bound variable occurs ONLY GUARDED
		-- under a constructor (rec / indexer / fn) — never bare in the union. An
		-- unguarded `μX.(nil|X)` is non-contractive and outside the slice grammar;
		-- the coinductive relation would (correctly, for the greatest fixpoint) read
		-- it as top, which is not what such a type is meant to denote.
		local base --[[: Ty ]]
		local bpick = rng:int(1, 4)
		if bpick == 1 then base = G.nil_()
		elseif bpick == 2 then base = G.integer()
		elseif bpick == 3 then base = G.string()
		else base = G.boolean() end
		return G.mu("X", function(x)
			local guard = rng:int(1, 3)
			local rec_arm --[[: Ty ]]
			if guard == 1 then
				rec_arm = G.rec({ fld("next", x) }, rng:int(1, 2) == 1 and "open" or "closed")
			elseif guard == 2 then
				rec_arm = G.indexer(G.integer(), x)
			else
				rec_arm = G.fn({ fixed = {} }, { fixed = { x } })
			end
			return G.union({ base, rec_arm })
		end)
	end
end

T.describe("slice_subtype fuzz invariants (§3.5)", function()
	G.reset()
	local rng = gen.make_rng(FUZZ_SEED)
	local seed_note = "seed=" .. tostring(FUZZ_SEED) .. " (replay: FUZZ_SEED=" .. tostring(FUZZ_SEED) .. ")"

	T.it("reflexivity: T <: T for every generated T  [" .. seed_note .. "]", function()
		for _ = 1, FUZZ_N do
			local t = gen_ty(rng, rng:int(0, 4), nil)
			T.ok(S.is_subtype(t, t), "reflexivity")
		end
	end)

	T.it("unknown/never laws  [" .. seed_note .. "]", function()
		for _ = 1, FUZZ_N do
			local t = gen_ty(rng, rng:int(0, 4), nil)
			-- always-true directions (§3.5).
			T.ok(S.is_subtype(t, G.unknown()), "T <: unknown")
			T.ok(S.is_subtype(G.never(), t), "never <: T")
			-- The negative laws hold for T not equivalent to top/bottom. A generated
			-- T can be SEMANTICALLY top (e.g. a μ that unfolds to unknown) while its
			-- syntactic kind is not "unknown"; gate on observable top-equivalence
			-- (`unknown <: T`) rather than the syntactic tag, so the law is exact.
			local t_is_top    = S.is_subtype(G.unknown(), t)
			local t_is_bottom = S.is_subtype(t, G.never())
			if not t_is_top then
				T.fail(S.is_subtype(G.unknown(), t), "unknown </: non-top T")
			end
			if not t_is_bottom then
				T.fail(S.is_subtype(t, G.never()), "non-bottom T </: never")
			end
		end
	end)

	T.it("transitivity sampling  [" .. seed_note .. "]", function()
		for _ = 1, FUZZ_N do
			local a = gen_ty(rng, rng:int(0, 3), nil)
			local b = gen_ty(rng, rng:int(0, 3), nil)
			local c = gen_ty(rng, rng:int(0, 3), nil)
			if S.is_subtype(a, b) and S.is_subtype(b, c) then
				T.ok(S.is_subtype(a, c), "A<:B and B<:C ⇒ A<:C")
			end
		end
	end)

	T.it("μ-unfolding equivalence  [" .. seed_note .. "]", function()
		local count = 0
		while count < FUZZ_N do
			local m = G.mu("X", function(x) return gen_ty(rng, rng:int(1, 3), x) end)
			if m.kind == "mu" then
				count = count + 1
				local u = G.unfold(m)
				T.ok(S.is_subtype(m, u), "μ <: unfold(μ)")
				T.ok(S.is_subtype(u, m), "unfold(μ) <: μ")
			else
				-- a μ whose body never used the binder normalizes away; still count it
				-- toward progress so the loop terminates.
				count = count + 1
			end
		end
	end)

	T.it("union/intersection lattice laws  [" .. seed_note .. "]", function()
		for _ = 1, FUZZ_N do
			local a = gen_ty(rng, rng:int(0, 3), nil)
			local b = gen_ty(rng, rng:int(0, 3), nil)
			local c = gen_ty(rng, rng:int(0, 3), nil)
			T.ok(S.is_subtype(a, G.union({ a, b })), "A <: A|B")
			T.ok(S.is_subtype(G.inter({ a, b }), a), "A&B <: A")
			-- union <: C  iff  A<:C and B<:C
			local lhs = S.is_subtype(G.union({ a, b }), c)
			local rhs = S.is_subtype(a, c) and S.is_subtype(b, c)
			T.eq(lhs, rhs, "A|B <: C  ⇔  A<:C ∧ B<:C")
			-- A <: inter  iff  A<:B and A<:C
			local lhs2 = S.is_subtype(a, G.inter({ b, c }))
			local rhs2 = S.is_subtype(a, b) and S.is_subtype(a, c)
			T.eq(lhs2, rhs2, "A <: B&C  ⇔  A<:B ∧ A<:C")
		end
	end)

	T.it("termination: every generated query completes (no hang)  [" .. seed_note .. "]", function()
		-- Deep/wide adversarial shapes. If any query did not terminate, the test
		-- runner would never reach the final assertion (timeout-30 would fire).
		for _ = 1, FUZZ_N do
			local a = gen_ty(rng, rng:int(2, 5), nil)
			local b = gen_ty(rng, rng:int(2, 5), nil)
			S.is_subtype(a, b)
			S.is_subtype(b, a)
		end
		T.ok(true, "all fuzz queries terminated")
	end)
end)
