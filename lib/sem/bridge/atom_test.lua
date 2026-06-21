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

	-- ── leg (1b): the Coq-validated oracle rows agree with real LuaJIT ────────
	T.it("Coq-oracle rows agree with real LuaJIT classification", function()
		if not probe(caps, LUAJIT) then
			T.skip("vendored LuaJIT not probeable; real-side leg skipped (bare-clone safe)")
			return
		end
		local rows = oracle()
		local agreed = 0
		for i = 1, #rows do
			local r = rows[i]
			local v = r.mk()
			local expr = bridge.value_to_lua_expr(v)
			local pred = bridge.atom_real_predicate(r.atom)
			local rv = real_verdict(caps, LUAJIT, expr, pred)
			T.neq(rv, nil, "real interpreter produced a verdict for " .. r.desc)
			-- The port (== the proven model) must match real LuaJIT.
			local model = bridge.model_denote_atom(r.atom, v)
			T.eq(rv, model, "model vs real LuaJIT: " .. r.desc)
			if rv == model then agreed = agreed + 1 end
		end
		print("  [bridge] oracle vs real LuaJIT: " .. agreed .. "/" .. #rows .. " agree")
		T.eq(agreed, #rows, "all oracle rows agree with real LuaJIT")
	end)

	-- ── leg (2): generated differential, model port vs real LuaJIT ────────────
	T.it("generated values: model port agrees with real LuaJIT for AStr/ABool/ANil", function()
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
end)
