-- lib/sem/diff/arb_program.lua
-- Generator producing ONLY v1-subset surface ASTs (lib/sem/lang/lua's SX/SS),
-- as an `arb`-shaped { generate, shrink } so Loop-α gets seed replay + shrinking
-- (lib/test/arb.lua's runner contract).
--
-- START NARROW (per the S1 plan): scalars + literals + arithmetic + comparison +
-- table construct/index/assign + function def/call with multi-return. The
-- programs are GUARANTEED WELL-SCOPED by construction: each expression is built
-- against the set of names already bound at that point, so a generated program
-- never references an unbound name (which would make the spec/real observations
-- diverge for a generator reason rather than a spec reason).
--
-- DEFERRED (noted): μ / union / intersection are type-level and have no runtime
-- step rule, so they are NOT generated here. Metatables, coroutines, general
-- for-in, and string library calls are out of the S1 fragment and not generated.
-- Division/modulo are generated but the generator avoids zero divisors where it
-- can; a `/0` still produces inf/nan which the observation space handles.
--
-- The generator is intentionally a single hand-written { generate, shrink } (not
-- a deep arb-combinator tree): well-scopedness is context-dependent, which the
-- point-free combinators cannot express. Scalar leaves still come from the arb
-- RNG, and the shrinker follows arb's contract (most-shrunk first; never re-runs
-- the generator).

--:: require "lib.sem.lang.lua.lower"

local M = {}

--:: Rng = { seed: number, next: (self: Rng) -> number, float: (self: Rng) -> number, int: (self: Rng, lo: integer, hi: integer) -> integer, bool: (self: Rng) -> boolean, pick: <T>(self: Rng, t: T[]) -> T }

-- ── leaf generators ──────────────────────────────────────────────────────────

--: (Rng) -> SX
local function gen_scalar(rng)
	local pick = rng:int(1, 4)
	if pick == 1 then
		local n = { x = "num", n = rng:int(-20, 20) } --[[: SX]]
		return n
	end
	if pick == 2 then
		-- small string from a safe identifier-ish charset (printable, no quotes).
		local cs = "abcXYZ_0 "
		local len = rng:int(0, 4)
		local buf = {} --[[: { [integer]: string } ]]
		for i = 1, len do
			local idx = rng:int(1, #cs)
			buf[i] = cs:sub(idx, idx)
		end
		local s = { x = "str", s = table.concat(buf) } --[[: SX]]
		return s
	end
	if pick == 3 then
		local b = { x = "bool", b = rng:bool() } --[[: SX]]
		return b
	end
	local z = { x = "nil" } --[[: SX]]
	return z
end

-- a name reference drawn from the bound set (assumes #names >= 1).
--: (Rng, string[]) -> SX
local function gen_name(rng, names)
	local nm = names[rng:int(1, #names)] or names[1] or "x0"
	local r = { x = "name", name = nm } --[[: SX]]
	return r
end

local ARITH = { "add", "sub", "mul" } --[[: { [integer]: string } ]]
local CMP = { "eq", "ne", "lt", "le", "gt", "ge" } --[[: { [integer]: string } ]]

-- ── expression generator (depth-bounded, well-scoped) ────────────────────────

--: (Rng, string[], integer) -> SX
function M.gen_expr(rng, names, depth)
	-- at depth 0, only leaves (keeps programs small + termination guaranteed).
	if depth <= 0 then
		if #names > 0 and rng:bool() then return gen_name(rng, names) end
		return gen_scalar(rng)
	end
	local choice = rng:int(1, 8)
	if choice == 1 then return gen_scalar(rng) end
	if choice == 2 then
		if #names > 0 then return gen_name(rng, names) end
		return gen_scalar(rng)
	end
	if choice == 3 then
		-- arithmetic on numbers (operands forced numeric to avoid trivial faults;
		-- the spec/real both fault on non-number arith — exercised separately by
		-- mixing in scalars at choice 4).
		local a = { x = "num", n = rng:int(-9, 9) } --[[: SX]]
		local b = { x = "num", n = rng:int(-9, 9) } --[[: SX]]
		local op = ARITH[rng:int(1, #ARITH)] or "add"
		local e = { x = "binop", op = op, a = a, b = b } --[[: SX]]
		return e
	end
	if choice == 4 then
		-- comparison over two sub-exprs (may fault if kinds mismatch — both sides
		-- agree on fault, which is the point of exercising it).
		local a = M.gen_expr(rng, names, depth - 1)
		local b = M.gen_expr(rng, names, depth - 1)
		local op = CMP[rng:int(1, #CMP)] or "eq"
		local e = { x = "binop", op = op, a = a, b = b } --[[: SX]]
		return e
	end
	if choice == 5 then
		-- table constructor with 0..3 items.
		local n = rng:int(0, 3)
		local items = {} --[[: { [integer]: SX } ]]
		for i = 1, n do
			local ie = M.gen_expr(rng, names, depth - 1) --: SX
			items[i] = ie
		end
		local e = { x = "table", items = items } --[[: SX]]
		return e
	end
	if choice == 6 then
		-- function literal taking 0..2 params, returning 1..2 exprs over params.
		local np = rng:int(0, 2)
		local params = {} --[[: { [integer]: string } ]]
		local inner = {} --[[: { [integer]: string } ]]
		for i = 1, #names do inner[i] = names[i] end
		for i = 1, np do
			local pn = "p" .. i
			params[i] = pn
			inner[#inner + 1] = pn
		end
		local nret = rng:int(1, 2)
		local rexprs = {} --[[: { [integer]: SX } ]]
		for i = 1, nret do
			local re = M.gen_expr(rng, inner, depth - 1) --: SX
			rexprs[i] = re
		end
		local body = { { s = "return", exprs = rexprs } } --[[: { [integer]: SS } ]]
		local e = { x = "func", params = params, vararg = rng:bool(), body = body } --[[: SX]]
		return e
	end
	if choice == 7 then
		-- index read off a freshly-built TABLE. S1 excludes metatables, so we never
		-- index a string/number (LuaJIT's string metatable would make ("a")[k] read
		-- the string library rather than fault — a corner OUTSIDE the S1 fragment;
		-- indexing only guaranteed tables keeps spec and real in-fragment agreement).
		local nitems = rng:int(0, 3)
		local items = {} --[[: { [integer]: SX } ]]
		for i = 1, nitems do
			local ie = M.gen_expr(rng, names, depth - 1) --: SX
			items[i] = ie
		end
		local obj = { x = "table", items = items } --[[: SX]]
		-- key: a small integer (in/out of range both valid: absent → nil).
		local key = { x = "num", n = rng:int(-2, 5) } --[[: SX]]
		local e = { x = "index", obj = obj, key = key } --[[: SX]]
		return e
	end
	-- default / choice 8: scalar.
	return gen_scalar(rng)
end

-- ── statement / program generator ────────────────────────────────────────────
-- A program is a sequence of `local` bindings (each over the names bound so far)
-- followed by a `return` of 1..3 expressions. This shape is always well-scoped.
--: (Rng, integer) -> SS[]
function M.gen_program(rng, size)
	local nlocals = rng:int(1, math.min(1 + size, 6))
	local names = {} --[[: { [integer]: string } ]]
	local stmts = {} --[[: { [integer]: SS } ]]
	for i = 1, nlocals do
		local nm = "v" .. i
		local expr = M.gen_expr(rng, names, rng:int(0, 2))
		local st = { s = "local", names = { nm }, exprs = { expr } } --[[: SS]]
		stmts[#stmts + 1] = st
		names[#names + 1] = nm
	end
	-- a return of 1..3 expressions.
	local nret = rng:int(1, 3)
	local rexprs = {} --[[: { [integer]: SX } ]]
	for i = 1, nret do
		local re = M.gen_expr(rng, names, rng:int(0, 2)) --: SX
		rexprs[i] = re
	end
	stmts[#stmts + 1] = { s = "return", exprs = rexprs } --[[: SS]]
	return stmts
end

-- ── arb-shaped wrapper ────────────────────────────────────────────────────────
-- generate(rng, sz) -> (prog, nil) ; shrink(prog, ctx) -> iter
-- Shrinking strategy (arb contract: most-shrunk first, never re-run generator):
--   phase 1 — drop the LAST non-return statement (shortens the program);
--   phase 2 — replace the return tuple with a single `nil` (simplest observable).
-- These two moves monotonically simplify and converge to `return nil`.

-- The generator exposes generate/shrink typed in terms of SS[] (the actual
-- value). The alpha test drives them directly (it does not route SS[] through
-- arb.lua's `unknown`-typed Arb slot), so the types stay precise and no force
-- cast is needed at a runner boundary.
-- The iterator yields the next-smaller program, or nil to stop. Its value slot is
-- typed `unknown` only because a union-of-records array is not reflexively
-- assignable in return position here (a typechecker gap recorded in TODO.md); the
-- runtime value is always an SS[] and the alpha test re-narrows it.
--:: ShrinkIter = () -> (unknown, nil)
--:: SemArb = { generate: (Rng, integer) -> (SS[], nil), shrink: (SS[], unknown) -> ShrinkIter }

M.arb = {
	--: (Rng, integer) -> (SS[], nil)
	generate = function(rng, sz)
		return M.gen_program(rng, sz), nil
	end,
	--: (SS[], unknown) -> ShrinkIter
	shrink = function(prog, _ctx)
		local phase = 1
		local emitted_return_nil = false
		return function()
			-- phase 1: drop the last non-return statement.
			if phase == 1 then
				phase = 2
				if #prog >= 2 then
					local out = {} --[[: { [integer]: SS } ]]
					-- copy all but the second-to-last (last is the return).
					for i = 1, #prog - 2 do out[i] = prog[i] end
					out[#out + 1] = prog[#prog]
					return out, nil
				end
			end
			-- phase 2: collapse the return to `return nil`.
			if not emitted_return_nil then
				emitted_return_nil = true
				local out = {} --[[: { [integer]: SS } ]]
				for i = 1, #prog - 1 do out[i] = prog[i] end
				local znil = { x = "nil" } --[[: SX]]
				out[#out + 1] = { s = "return", exprs = { znil } } --[[: SS]]
				return out, nil
			end
			return nil, nil
		end
	end,
}

return M
