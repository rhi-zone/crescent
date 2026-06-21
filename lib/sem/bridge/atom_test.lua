-- lib/sem/bridge/atom_test.lua
-- REALITY-BRIDGE differential pipeline for the UNAMBIGUOUS atoms (AStr, ABool,
-- ANil). Three legs (docs/reality-bridge.md):
--
--   (1) Coq-oracle validation. A baked-in table of (atom, value) → verdict, each
--       entry being the EXACT result of `Compute (memb atom value)` on the proven
--       Coq model (proof/subtype.v `denote_dec`; transcript reproduced in the
--       doc). We assert the Lua port `bridge.model_denote_atom` agrees with every
--       Coq verdict — so the port is a trustworthy proxy for the PROVEN model.
--
--   (2) model↔reality differential. Generate model values, render each to a real
--       Lua expression, and for each (unambiguous atom, value) assert the port's
--       verdict MATCHES real LuaJIT's classification (`type(x)`), obtained by
--       shelling the vendored interpreter through an INJECTED popen cap. Report
--       the agreement count.
--
--   (3) deterministic spot-checks across all heads, same path.
--
-- CAPS-FIRST: the real interpreter is reached ONLY through injected caps wired at
-- the top (popen/open/remove/tmpname). The vendored LuaJIT (./bin/luajit) is the
-- runtime and assumed present; if it cannot be probed the real-side legs SKIP
-- gracefully (never fail) so `bin/cr test` stays green on a bare clone.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local exec   = require("lib.exec")
local gen    = require("lib.test.gen")
local bridge = require("lib.sem.bridge.atom")

--:: require "lib.caps.types"
--:: require "lib.sem.bridge.atom"

--:: Rng = { seed: number, next: (self: Rng) -> number, float: (self: Rng) -> number, int: (self: Rng, lo: integer, hi: integer) -> integer, bool: (self: Rng) -> boolean, pick: <T>(self: Rng, t: T[]) -> T }
--:: ExecCaps = { popen: POpenFn, open: OpenFn, remove: RemoveFn, tmpname: TmpnamFn }

local LUAJIT = "./bin/luajit"

-- ── caps-first interpreter probe ─────────────────────────────────────────────
--: (ExecCaps, string) -> boolean
local function probe(caps, cmd)
	local out = exec.run(cmd, { "-e", "io.write('crbridge-probe')" },
		{ popen = caps.popen, stderr = "discard" })
	if out == nil then return false end
	return out:find("crbridge-probe", 1, true) ~= nil
end

-- ── (1) the Coq oracle table ─────────────────────────────────────────────────
-- Each row is the verbatim verdict of `Compute (memb (BAtom <atom>) <value>)` on
-- the proven model, where  memb t v := if denote_dec t v then true else false.
-- Reproduced from the coqc transcript in docs/reality-bridge.md. The `mk` builder
-- maps the symbolic value to the Lua port's ModelValue.
--:: OracleRow = { atom: BridgeAtom, mk: () -> ModelValue, coq: boolean, desc: string }
--: () -> OracleRow[]
local function oracle()
	local rows = {
		-- AStr
		{ atom = "AStr",  mk = function() return bridge.vstr("hi") end,  coq = true,  desc = "AStr VStr" },
		{ atom = "AStr",  mk = function() return bridge.vint(7) end,     coq = false, desc = "AStr VInt" },
		{ atom = "AStr",  mk = function() return bridge.vbool(true) end, coq = false, desc = "AStr VBool" },
		{ atom = "AStr",  mk = function() return bridge.vnil() end,      coq = false, desc = "AStr VNil" },
		-- ABool
		{ atom = "ABool", mk = function() return bridge.vbool(true) end,  coq = true,  desc = "ABool VBool true" },
		{ atom = "ABool", mk = function() return bridge.vbool(false) end, coq = true,  desc = "ABool VBool false" },
		{ atom = "ABool", mk = function() return bridge.vstr("x") end,    coq = false, desc = "ABool VStr" },
		{ atom = "ABool", mk = function() return bridge.vint(0) end,      coq = false, desc = "ABool VInt" },
		-- ANil
		{ atom = "ANil",  mk = function() return bridge.vnil() end,       coq = true,  desc = "ANil VNil" },
		{ atom = "ANil",  mk = function() return bridge.vstr("x") end,    coq = false, desc = "ANil VStr" },
		{ atom = "ANil",  mk = function() return bridge.vbool(false) end, coq = false, desc = "ANil VBool" },
		{ atom = "ANil",  mk = function() return bridge.vfloat(3.0) end,  coq = false, desc = "ANil VFloat" },
		-- ANum (number atom under REFINE) — verbatim from bridge_num_oracle.v
		{ atom = "ANum",  mk = function() return bridge.vint(3) end,      coq = true,  desc = "ANum VInt 3" },
		{ atom = "ANum",  mk = function() return bridge.vfloat(3.0) end,  coq = true,  desc = "ANum VFloat 3" },
		{ atom = "ANum",  mk = function() return bridge.vint(0) end,      coq = true,  desc = "ANum VInt 0" },
		{ atom = "ANum",  mk = function() return bridge.vstr("x") end,    coq = false, desc = "ANum VStr" },
		{ atom = "ANum",  mk = function() return bridge.vbool(true) end,  coq = false, desc = "ANum VBool" },
		{ atom = "ANum",  mk = function() return bridge.vnil() end,       coq = false, desc = "ANum VNil" },
		-- AInt (refinement) — VFloat 3 is FALSE in the model (the central fork)
		{ atom = "AInt",  mk = function() return bridge.vint(3) end,      coq = true,  desc = "AInt VInt 3" },
		{ atom = "AInt",  mk = function() return bridge.vint(0) end,      coq = true,  desc = "AInt VInt 0" },
		{ atom = "AInt",  mk = function() return bridge.vfloat(3.0) end,  coq = false, desc = "AInt VFloat 3 (model: NOT int)" },
		{ atom = "AInt",  mk = function() return bridge.vstr("x") end,    coq = false, desc = "AInt VStr" },
		{ atom = "AInt",  mk = function() return bridge.vbool(false) end, coq = false, desc = "AInt VBool" },
	}
	return rows
end

-- ── (2) real-side classification ─────────────────────────────────────────────
-- Build a Lua chunk that binds `x` to the rendered value expression, evaluates
-- the atom's real-Lua predicate, and prints "T" or "F". Returns the real verdict
-- as a boolean (or nil on interpreter failure).
--: (ExecCaps, string, string, string) -> (boolean | nil)
local function real_verdict(caps, cmd, value_expr, predicate)
	local src = "local x = " .. value_expr .. "\n"
		.. "io.write((" .. predicate .. ") and 'T' or 'F')\n"
	local path = caps.tmpname() .. ".bridge.lua"
	local fh = caps.open(path, "w")
	if fh == nil then error("bridge: cannot open temp file " .. path) end
	fh:write(src)
	fh:close()
	local out = exec.run(cmd, { path }, { popen = caps.popen, stderr = "discard" })
	caps.remove(path)
	if out == nil then return nil end
	if out:find("T", 1, true) ~= nil then return true end
	if out:find("F", 1, true) ~= nil then return false end
	return nil
end

-- ── value generator (the unambiguous-fragment value space) ───────────────────
-- Generates model values across ALL heads, so the differential exercises both
-- membership (the matching head) and rejection (every other head).
--: (Rng, integer) -> unknown
local function gen_model_value(rng, sz)
	local which = rng:int(1, 7)
	if which == 1 then
		local s = gen.string({ max = math.min(sz, 8) }).generate(rng, sz) --[[: string]]
		return bridge.vstr(s)
	elseif which == 2 then
		return bridge.vbool(rng:bool())
	elseif which == 3 then
		return bridge.vnil()
	elseif which == 4 then
		return bridge.vint(rng:int(-1000, 1000))
	elseif which == 5 then
		-- a genuinely non-integer float (offset by a fraction).
		return bridge.vfloat(rng:int(-1000, 1000) + 0.5)
	elseif which == 6 then
		return bridge.vtable()
	else
		return bridge.vfun()
	end
end

T.describe("sem reality-bridge: model atom-denotation vs real LuaJIT (unambiguous atoms)", function()
	local caps = {
		popen = io.popen, open = io.open, remove = os.remove, tmpname = os.tmpname,
	} --[[: ExecCaps]]

	-- ── leg (1): the Lua port agrees with the proven Coq model ────────────────
	T.it("Lua atom-denotation port matches the Coq Compute verdicts", function()
		local rows = oracle()
		for i = 1, #rows do
			local r = rows[i]
			local v = r.mk()
			local got = bridge.model_denote_atom(r.atom, v)
			T.eq(got, r.coq,
				"port vs Coq oracle: " .. r.desc .. " (Coq says " .. tostring(r.coq) .. ")")
		end
		print("  [bridge] Coq-oracle: " .. #rows .. "/" .. #rows .. " port verdicts match the proven model")
	end)

	-- ── leg (1b): the Coq-validated oracle rows vs real LuaJIT ────────────────
	-- Most rows AGREE. The number atoms surface the value-domain fork: the row
	-- `AInt VFloat 3` is a KNOWN disagreement — the MODEL says VFloat 3 ∉ AInt,
	-- but its real-Lua image is the double `3.0`, which satisfies the integral
	-- predicate. We classify each row and assert the disagreement set is EXACTLY
	-- the integer-valued-VFloat-vs-AInt case (the surfaced fork), nothing else.
	T.it("Coq-oracle rows vs real LuaJIT (number atoms surface the value-domain fork)", function()
		if not probe(caps, LUAJIT) then
			T.skip("vendored LuaJIT not probeable; real-side leg skipped (bare-clone safe)")
			return
		end
		local rows = oracle()
		local agreed = 0
		local known_disagree = {} --: string[]
		for i = 1, #rows do
			local r = rows[i]
			local v = r.mk()
			local expr = bridge.value_to_lua_expr(v)
			local pred = bridge.atom_real_predicate(r.atom)
			local rv = real_verdict(caps, LUAJIT, expr, pred)
			T.neq(rv, nil, "real interpreter produced a verdict for " .. r.desc)
			local model = bridge.model_denote_atom(r.atom, v)
			if rv == model then
				agreed = agreed + 1
			else
				-- The only admissible disagreement: model says a VFloat with an
				-- integer value is NOT an int, but its real double IS integral.
				T.eq(r.atom, "AInt", "unexpected disagreement on " .. r.desc)
				T.eq(v.head, "VFloat", "unexpected disagreement on " .. r.desc)
				T.eq(model, false, "fork witness: model says VFloat ∉ AInt")
				T.eq(rv, true, "fork witness: real double IS integral")
				known_disagree[#known_disagree + 1] = r.desc
			end
		end
		print("  [bridge] oracle vs real LuaJIT: " .. agreed .. "/" .. #rows
			.. " agree; " .. #known_disagree .. " known value-domain-fork disagreement(s)")
		for i = 1, #known_disagree do
			print("    [fork] " .. known_disagree[i]
				.. " — VInt/VFloat-vs-5.1: distinct model values, one real double")
		end
		T.eq(#known_disagree, 1, "exactly one surfaced disagreement (AInt VFloat 3)")
		T.eq(agreed, #rows - 1, "all other oracle rows agree with real LuaJIT")
	end)

	-- ── leg (1c): explicit witness — VInt 3 and VFloat 3 are the SAME real value
	-- The central faithfulness question, pinned concretely: distinct model values
	-- VInt 3 / VFloat 3 both map to the real double 3, which is `==` and renders
	-- identically. So the model's VInt/VFloat distinction is UNOBSERVABLE on 5.1.
	T.it("witness: VInt 3 and VFloat 3 are indistinguishable in real LuaJIT 5.1", function()
		if not probe(caps, LUAJIT) then
			T.skip("vendored LuaJIT not probeable; witness leg skipped (bare-clone safe)")
			return
		end
		local int_expr   = bridge.value_to_lua_expr(bridge.vint(3))   --[[: string]]
		local float_expr = bridge.value_to_lua_expr(bridge.vfloat(3)) --[[: string]]
		-- Equality, type, and tostring of the two images, evaluated for real.
		local src = "local a = " .. int_expr .. "\n"
			.. "local b = " .. float_expr .. "\n"
			.. "io.write((a == b) and 'EQ' or 'NE', '|', type(a), '|', type(b),"
			.. " '|', tostring(a), '|', tostring(b))\n"
		local path = caps.tmpname() .. ".bridge-witness.lua"
		local fh = caps.open(path, "w")
		if fh == nil then error("bridge: cannot open temp file " .. path) end
		fh:write(src); fh:close()
		local out = exec.run(LUAJIT, { path }, { popen = caps.popen, stderr = "discard" })
		caps.remove(path)
		T.neq(out, nil, "witness interpreter produced output")
		print("  [bridge] witness VInt 3 vs VFloat 3 in real LuaJIT: " .. tostring(out))
		-- distinct model values, ONE real value: equal, both "number", same tostring.
		T.ok((out or ""):find("EQ", 1, true) ~= nil,
			"VInt 3 == VFloat 3 in real LuaJIT 5.1 (one double)")
		T.ok((out or ""):find("number|number", 1, true) ~= nil,
			"both classify as type=='number' (no runtime int/float tag)")
	end)

	-- ── leg (2): generated differential, model port vs real LuaJIT ────────────
	-- Over all 5 bridged atoms (AStr/ABool/ANil/ANum/AInt). The generator emits
	-- non-integer floats (offset .5) for the VFloat head, so model and real
	-- predicate agree on every generated value — the integer-valued-VFloat fork
	-- case is exercised separately by the oracle/witness legs (1b/1c) and is NOT
	-- reachable here. Any disagreement here would be a genuine, unexpected bug.
	T.it("generated values: model port agrees with real LuaJIT for all 5 bridged atoms", function()
		if not probe(caps, LUAJIT) then
			T.skip("vendored LuaJIT not probeable; differential leg skipped (bare-clone safe)")
			return
		end

		local seed = os.time() --: number
		local seed_env = os.getenv("PROP_SEED")
		if seed_env ~= nil then
			local parsed = tonumber(seed_env)
			if parsed ~= nil then seed = parsed end
		end
		local rng = gen.make_rng(math.floor(seed)) --: Rng

		local n_values = 100
		local atoms = bridge.atoms
		local checked = 0
		local agreed = 0
		local first_fail --: string | nil

		for i = 1, n_values do
			local v = gen_model_value(rng, math.min(i, 8))
			local expr = bridge.value_to_lua_expr(v) --[[: string]]
			for ai = 1, #atoms do
				local atom = atoms[ai]
				local model = bridge.model_denote_atom(atom, v)
				local pred = bridge.atom_real_predicate(atom)
				local rv = real_verdict(caps, LUAJIT, expr, pred)
				checked = checked + 1
				if rv == nil then
					if first_fail == nil then
						first_fail = "real interpreter gave no verdict for atom=" .. atom
							.. " value=" .. expr
					end
				elseif rv == model then
					agreed = agreed + 1
				elseif first_fail == nil then
					first_fail = "FAITHFULNESS DISAGREEMENT (replay PROP_SEED=" .. seed .. "): "
						.. "atom=" .. atom .. " value=" .. expr
						.. " model says " .. tostring(model)
						.. " real LuaJIT says " .. tostring(rv)
				end
			end
		end

		print("  [bridge] differential: " .. agreed .. "/" .. checked
			.. " agree (" .. n_values .. " values x " .. #atoms .. " atoms)")
		if first_fail ~= nil then
			T.ok(false, first_fail)
		end
		T.eq(agreed, checked,
			"all " .. checked .. " (atom,value) classifications agree (got " .. agreed .. ")")
	end)

	-- ── leg (3): REAL-value REFINE differential for ANum/AInt ─────────────────
	-- Generate REAL Lua numbers (integer-valued, non-integer, and edge cases
	-- inf/nan/-0.0/large) and assert the host-side REFINE classifier
	-- (`real_refine_class`) agrees with the SHELLED real predicate
	-- (`atom_real_predicate`). This validates the REFINE predicate itself against
	-- the real interpreter on edge cases the model-value generator can't express.
	T.it("real-value REFINE differential: ANum/AInt classification on edge cases", function()
		if not probe(caps, LUAJIT) then
			T.skip("vendored LuaJIT not probeable; real-value leg skipped (bare-clone safe)")
			return
		end
		-- (expr, host-value) pairs. Host value mirrors what the real expr yields,
		-- so we can compute `real_refine_class` host-side and check it shells the
		-- same way. inf/nan/-0.0 are written as expressions (no Lua literal).
		--:: NumCase = { expr: string, host: number }
		local cases = {
			{ expr = "0",        host = 0 },
			{ expr = "3",        host = 3 },
			{ expr = "-7",       host = -7 },
			{ expr = "1.5",      host = 1.5 },
			{ expr = "2.25",     host = 2.25 },
			{ expr = "-0.0",     host = -0.0 },
			{ expr = "3.0",      host = 3.0 },     -- integer-valued FLOAT literal
			{ expr = "1/0",      host = 1 / 0 },   -- +inf
			{ expr = "-1/0",     host = -1 / 0 },  -- -inf
			{ expr = "0/0",      host = 0 / 0 },   -- nan
			{ expr = "2^53",     host = 2 ^ 53 },  -- large integer-valued
			{ expr = "2^53+0.5", host = 2 ^ 53 + 0.5 },
		} --[[: NumCase[] ]]
		-- Expected REFINE classification (independent of host helper, for clarity).
		--:: Expect = { ANum: boolean, AInt: boolean }
		local num_atoms = { "ANum", "AInt" } --[[: ("ANum" | "AInt")[] ]]
		local checked = 0
		local agreed = 0
		local first_fail --: string | nil
		for i = 1, #cases do
			local c = cases[i]
			for ai = 1, #num_atoms do
				local atom = num_atoms[ai]
				local host = bridge.real_refine_class(atom, c.host)
				local pred = bridge.atom_real_predicate(atom)
				local rv = real_verdict(caps, LUAJIT, c.expr, pred)
				checked = checked + 1
				if rv == nil then
					if first_fail == nil then
						first_fail = "no verdict for atom=" .. atom .. " expr=" .. c.expr
					end
				elseif rv == host then
					agreed = agreed + 1
				elseif first_fail == nil then
					first_fail = "REFINE host vs real mismatch: atom=" .. atom
						.. " expr=" .. c.expr .. " host=" .. tostring(host)
						.. " real=" .. tostring(rv)
				end
			end
		end
		print("  [bridge] real-value REFINE: " .. agreed .. "/" .. checked
			.. " agree (" .. #cases .. " numbers x 2 atoms)")
		-- Spot-check the intended classifications explicitly (documents REFINE).
		T.eq(bridge.real_refine_class("AInt", 3.0), true,  "3.0 is integer-valued ⇒ AInt")
		T.eq(bridge.real_refine_class("AInt", 1.5), false, "1.5 ⇒ not AInt")
		T.eq(bridge.real_refine_class("AInt", 1 / 0), false, "+inf ⇒ not AInt")
		T.eq(bridge.real_refine_class("AInt", 0 / 0), false, "nan ⇒ not AInt")
		T.eq(bridge.real_refine_class("ANum", 0 / 0), true,  "nan IS a number ⇒ ANum")
		T.eq(bridge.real_refine_class("AInt", -0.0), true, "-0.0 is integer-valued ⇒ AInt")
		if first_fail ~= nil then T.ok(false, first_fail) end
		T.eq(agreed, checked, "all real-value REFINE classifications agree")
	end)
end)
