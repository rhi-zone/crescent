-- lib/sem/bridge/fun_test.lua
-- REALITY-BRIDGE differential pipeline for FUNCTION values + ARROW types (fork B,
-- docs/reality-bridge.md). The model's `VFun` is a finite KNOWN I/O graph, so it
-- IS bridgeable: we build a real Lua function FROM the graph and check both
--
--   (operational) application = graph lookup: real_f(real(i)) == real(o) for each
--       (i,o) in the graph — real Lua's call semantics matches the model's
--       graph-lookup denotation.
--   (membership) arrow verdict: the MODEL verdict (port of `denote_dec
--       (BArrow A B) (VFun g)`) AGREES with the REAL-computed verdict (per-pair
--       `real(i)∈A → real(o)∈B`, using the atom bridge's REAL atom predicates).
--
-- Plus a Coq-oracle leg: ~10 concrete (arrow-type, VFun-graph) cases whose
-- verbatim `Compute (memb (BArrow A B) (VFun g))` verdicts (proof/bridge_arrow_
-- oracle.v) are asserted to match the Lua model-verdict port — so the bridge's
-- model side faithfully reflects the PROVEN model. Includes member AND non-member
-- cases (e.g. Int->Str graph NOT in Int->Int).
--
-- SCOPE: SCALAR graph entries only (number/string/bool/nil). Higher-order
-- (functions in graphs) and table-valued graph entries DEFERRED (TODO.md
-- proof-dev backlog).
--
-- CAPS-FIRST: the real interpreter is reached ONLY through injected caps. If the
-- vendored LuaJIT cannot be probed, the real-side legs SKIP gracefully (never
-- fail) so `bin/cr test` stays green on a bare clone.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local exec   = require("lib.exec")
local gen    = require("lib.test.gen")
local atom   = require("lib.sem.bridge.atom")
local fun    = require("lib.sem.bridge.fun")

--:: require "lib.caps.types"
--:: require "lib.sem.bridge.atom"
--:: require "lib.sem.bridge.fun"

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

-- ── run a Lua chunk in the real interpreter, return stdout (or nil) ──────────
--: (ExecCaps, string, string) -> (string | nil)
local function run_chunk(caps, cmd, src)
	local path = caps.tmpname() .. ".bridge-fun.lua"
	local fh = caps.open(path, "w")
	if fh == nil then error("bridge: cannot open temp file " .. path) end
	fh:write(src)
	fh:close()
	local out = exec.run(cmd, { path }, { popen = caps.popen, stderr = "discard" })
	caps.remove(path)
	return out
end

-- ── (operational leg) real application == graph lookup ───────────────────────
-- Build the real Lua function from the graph, apply it to each input's real
-- image, and report whether every result `==` the corresponding output's real
-- image. Emits one token per pair: 'T' (agree) or 'F' (disagree); returns the
-- concatenated tokens (or nil on interpreter failure).
--: (ExecCaps, string, MVFunGraph) -> (string | nil)
local function operational_tokens(caps, cmd, vfun)
	local g = vfun.graph
	local fn_expr = fun.graph_to_lua_function_expr(g) --[[: string]]
	local lines = {} --[[: { [integer]: string } ]]
	lines[#lines + 1] = "local f = " .. fn_expr
	for k = 1, #g do
		local in_expr  = atom.value_to_lua_expr(g[k].i) --[[: string]]
		local out_expr = atom.value_to_lua_expr(g[k].o) --[[: string]]
		-- apply f to the input image; compare to the output image with `==`.
		lines[#lines + 1] = "io.write((f(" .. in_expr .. ") == (" .. out_expr
			.. ")) and 'T' or 'F')"
	end
	return run_chunk(caps, cmd, table.concat(lines, "\n") .. "\n")
end

-- ── (membership leg) real arrow verdict over the graph ───────────────────────
-- For each pair, evaluate the per-pair implication `real(i)∈A → real(o)∈B` in the
-- real interpreter; the arrow verdict is the AND over all pairs. Empty graph ⇒
-- vacuously true. Returns the real verdict as a boolean (or nil on failure).
--: (ExecCaps, string, string, string, MVFunGraph) -> (boolean | nil)
local function real_arrow_verdict(caps, cmd, a_dom, a_cod, vfun)
	local g = vfun.graph
	if #g == 0 then return true end -- vacuous
	local impl = fun.pair_real_implication_expr(a_dom, a_cod) --[[: string]]
	local lines = {} --[[: { [integer]: string } ]]
	lines[#lines + 1] = "local ok = true"
	for k = 1, #g do
		local in_expr  = atom.value_to_lua_expr(g[k].i) --[[: string]]
		local out_expr = atom.value_to_lua_expr(g[k].o) --[[: string]]
		lines[#lines + 1] = "do local xi = " .. in_expr .. "; local xo = " .. out_expr
			.. "; if not (" .. impl .. ") then ok = false end end"
	end
	lines[#lines + 1] = "io.write(ok and 'T' or 'F')"
	local out = run_chunk(caps, cmd, table.concat(lines, "\n") .. "\n")
	if out == nil then return nil end
	if out:find("T", 1, true) ~= nil then return true end
	if out:find("F", 1, true) ~= nil then return false end
	return nil
end

-- ── the Coq oracle table (verbatim from proof/bridge_arrow_oracle.v) ─────────
-- Each row: an arrow type (dom,cod atoms) + a VFun graph + the Coq `Compute`
-- verdict. The graphs are built from the atom bridge's scalar value constructors.
--:: ArrowOracleRow = { dom: ArrowAtom, cod: ArrowAtom, mk: () -> MVFunGraph, coq: boolean, desc: string }
-- pair / graph builders (keep each `mk` a single-line lambda so its signature is
-- inferred from the ArrowOracleRow[] field type — no per-lambda annotation needed).
--: (ModelValue, ModelValue) -> GraphPair
local function p(i, o) return { i = i, o = o } end
--: (...GraphPair) -> MVFunGraph
local function g(...) return fun.vfun_graph({ ... }) end

--: () -> ArrowOracleRow[]
local function arrow_oracle()
	local vi, vs, vb, vf = atom.vint, atom.vstr, atom.vbool, atom.vfloat
	-- NB: `mk` is the FIRST field of each row so the ArrowOracleRow[] field type
	-- pushes its signature down (the checker resolves the contextual type left to
	-- right; placing the lambda first lets it be checked against `() -> MVFunGraph`).
	local rows = {
		-- member cases
		{ mk = function() return g() end, dom = "AInt", cod = "AInt", coq = true,
			desc = "Int->Int (empty graph: vacuous)" },
		{ mk = function() return g(p(vi(1), vi(2)), p(vi(3), vi(4))) end, dom = "AInt", cod = "AInt", coq = true,
			desc = "Int->Int [(1,2),(3,4)]" },
		{ mk = function() return g(p(vi(1), vi(2)), p(vs(), vs())) end, dom = "AInt", cod = "AInt", coq = true,
			desc = "Int->Int [(1,2),(\"x\",\"y\")] (non-int input vacuous)" },
		{ mk = function() return g(p(vs(), vb(true))) end, dom = "AStr", cod = "ABool", coq = true,
			desc = "Str->Bool [(\"k\",true)]" },
		{ mk = function() return g(p(vi(5), vi(6))) end, dom = "ANum", cod = "ANum", coq = true,
			desc = "Num->Num [(5,6)] (AInt <: ANum)" },
		-- NON-member cases
		{ mk = function() return g(p(vi(1), vs())) end, dom = "AInt", cod = "AInt", coq = false,
			desc = "Int->Int [(1,\"s\")] — int input -> str output (NON-member)" },
		{ mk = function() return g(p(vi(1), vf(2))) end, dom = "AInt", cod = "AInt", coq = false,
			desc = "Int->Int [(1,2.5)] — int -> non-integer (NON-member)" },
		{ mk = function() return g(p(vs(), vi(9))) end, dom = "AStr", cod = "ABool", coq = false,
			desc = "Str->Bool [(\"k\",9)] — str input -> int output (NON-member)" },
	}
	return rows
end

-- ── random scalar value (for generated graphs) ───────────────────────────────
--: (Rng, integer) -> ModelValue
local function gen_scalar(rng, sz)
	local which = rng:int(1, 5)
	if which == 1 then
		-- single (nullary) model string value; AStr membership is head-only.
		return atom.vstr()
	elseif which == 2 then
		return atom.vbool(rng:bool())
	elseif which == 3 then
		return atom.vnil()
	elseif which == 4 then
		return atom.vint()
	else
		return atom.vfloat()
	end
end

-- ── random graph: a finite list of scalar (input,output) pairs. To keep the
-- real dispatch well-defined we make inputs DISTINCT real images (dedupe by the
-- rendered Lua expression of the input), so `f(i)` is unambiguous. ──────────
--: (Rng, integer) -> MVFunGraph
local function gen_graph(rng, sz)
	local n = rng:int(0, 4)
	local pairs_acc = {} --: GraphPair[]
	local seen = {} --: { [string]: boolean }
	for _ = 1, n do
		local i = gen_scalar(rng, sz)
		local o = gen_scalar(rng, sz)
		local key = atom.value_to_lua_expr(i) --[[: string]]
		if not seen[key] then
			seen[key] = true
			pairs_acc[#pairs_acc + 1] = { i = i, o = o }
		end
	end
	return fun.vfun_graph(pairs_acc)
end

T.describe("sem reality-bridge: model VFun graph vs real LuaJIT function + arrow membership", function()
	local caps = {
		popen = io.popen, open = io.open, remove = os.remove, tmpname = os.tmpname,
	} --[[: ExecCaps]]

	-- ── leg (1): the Lua model-verdict port agrees with the proven Coq model ──
	T.it("Lua arrow-membership port matches the Coq Compute verdicts (member + non-member)", function()
		local rows = arrow_oracle()
		for i = 1, #rows do
			local r = rows[i]
			local got = fun.model_arrow_verdict(r.dom, r.cod, r.mk())
			T.eq(got, r.coq,
				"port vs Coq oracle: " .. r.desc .. " (Coq says " .. tostring(r.coq) .. ")")
		end
		print("  [bridge] arrow Coq-oracle: " .. #rows .. "/" .. #rows
			.. " model-verdicts match the proven model")
	end)

	-- ── leg (2a): OPERATIONAL — real application == graph lookup ──────────────
	-- For each oracle graph, build the real Lua function and assert
	-- real_f(real(i)) == real(o) for every (i,o). This validates real Lua's
	-- call semantics against the model's graph-lookup denotation.
	T.it("operational: real application equals graph lookup for every oracle graph", function()
		if not probe(caps, LUAJIT) then
			T.skip("vendored LuaJIT not probeable; operational leg skipped (bare-clone safe)")
			return
		end
		local rows = arrow_oracle()
		local pairs_total = 0
		local pairs_ok = 0
		local first_fail --: string | nil
		for i = 1, #rows do
			local vfun = rows[i].mk()
			local np = #vfun.graph
			if np > 0 then
				local toks = operational_tokens(caps, LUAJIT, vfun)
				if toks == nil then
					if first_fail == nil then
						first_fail = "no operational verdict for " .. rows[i].desc
					end
				else
					-- count tokens; each pair contributes one T/F.
					for k = 1, np do
						pairs_total = pairs_total + 1
						local ch = toks:sub(k, k)
						if ch == "T" then
							pairs_ok = pairs_ok + 1
						elseif first_fail == nil then
							first_fail = "operational mismatch in " .. rows[i].desc
								.. " (pair " .. k .. ": real_f(i) ~= o)"
						end
					end
				end
			end
		end
		print("  [bridge] operational: " .. pairs_ok .. "/" .. pairs_total
			.. " application==graph-lookup over oracle graphs")
		if first_fail ~= nil then T.ok(false, first_fail) end
		T.eq(pairs_ok, pairs_total, "every real application matches the graph output")
	end)

	-- ── leg (2b): MEMBERSHIP — model arrow verdict == real-computed verdict ───
	-- For each oracle row, assert the model port verdict AGREES with the
	-- real-computed verdict (per-pair real(i)∈A → real(o)∈B).
	T.it("membership: model arrow verdict agrees with real-computed verdict (oracle rows)", function()
		if not probe(caps, LUAJIT) then
			T.skip("vendored LuaJIT not probeable; membership leg skipped (bare-clone safe)")
			return
		end
		local rows = arrow_oracle()
		local agreed = 0
		local disagree = {} --: string[]
		for i = 1, #rows do
			local r = rows[i]
			local vfun = r.mk()
			local model = fun.model_arrow_verdict(r.dom, r.cod, vfun)
			local real  = real_arrow_verdict(caps, LUAJIT, r.dom, r.cod, vfun)
			T.neq(real, nil, "real interpreter produced an arrow verdict for " .. r.desc)
			if real == model then
				agreed = agreed + 1
			else
				disagree[#disagree + 1] = r.desc
					.. " (model=" .. tostring(model) .. " real=" .. tostring(real) .. ")"
			end
		end
		print("  [bridge] membership (oracle): " .. agreed .. "/" .. #rows
			.. " agree; " .. #disagree .. " disagreement(s)")
		for i = 1, #disagree do print("    [DISAGREE] " .. disagree[i]) end
		T.eq(#disagree, 0, "no model-vs-real arrow-verdict disagreements on oracle rows")
	end)

	-- ── leg (3): DIFFERENTIAL — random graphs × random scalar arrow types ─────
	-- Generate random finite scalar graphs and random scalar arrow types A->B;
	-- build the real function; run BOTH legs; assert agreement. Report counts.
	T.it("differential: random graphs x random arrow types — both legs agree", function()
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

		local n_trials = 60
		local atoms = fun.arrow_atoms

		local op_total, op_ok = 0, 0
		local mem_total, mem_ok = 0, 0
		local first_fail --: string | nil

		for t = 1, n_trials do
			local vfun = gen_graph(rng, math.min(t, 8))
			local a_dom = rng:pick(atoms) --[[: ArrowAtom]]
			local a_cod = rng:pick(atoms) --[[: ArrowAtom]]

			-- operational leg (only when the graph is non-empty)
			if #vfun.graph > 0 then
				local toks = operational_tokens(caps, LUAJIT, vfun)
				if toks == nil then
					if first_fail == nil then
						first_fail = "no operational verdict (PROP_SEED=" .. seed .. ", trial " .. t .. ")"
					end
				else
					for k = 1, #vfun.graph do
						op_total = op_total + 1
						if toks:sub(k, k) == "T" then
							op_ok = op_ok + 1
						elseif first_fail == nil then
							local p = vfun.graph[k]
							first_fail = "OPERATIONAL DISAGREEMENT (replay PROP_SEED=" .. seed
								.. "): graph pair " .. k .. " i="
								.. atom.value_to_lua_expr(p.i) .. " o=" .. atom.value_to_lua_expr(p.o)
								.. " real_f(i) ~= o"
						end
					end
				end
			end

			-- membership leg
			local model = fun.model_arrow_verdict(a_dom, a_cod, vfun)
			local real  = real_arrow_verdict(caps, LUAJIT, a_dom, a_cod, vfun)
			mem_total = mem_total + 1
			if real == nil then
				if first_fail == nil then
					first_fail = "no membership verdict (PROP_SEED=" .. seed .. ", trial " .. t .. ")"
				end
			elseif real == model then
				mem_ok = mem_ok + 1
			elseif first_fail == nil then
				-- minimal witness: the graph + the arrow type
				local gdesc = {} --[[: { [integer]: string } ]]
				for k = 1, #vfun.graph do
					gdesc[#gdesc + 1] = "(" .. atom.value_to_lua_expr(vfun.graph[k].i)
						.. "," .. atom.value_to_lua_expr(vfun.graph[k].o) .. ")"
				end
				first_fail = "MEMBERSHIP DISAGREEMENT (replay PROP_SEED=" .. seed .. "): "
					.. a_dom .. "->" .. a_cod .. " graph=[" .. table.concat(gdesc, ",") .. "]"
					.. " model=" .. tostring(model) .. " real=" .. tostring(real)
			end
		end

		print("  [bridge] differential operational: " .. op_ok .. "/" .. op_total
			.. " agree (random graphs)")
		print("  [bridge] differential membership:  " .. mem_ok .. "/" .. mem_total
			.. " agree (random graphs x arrow types)")
		if first_fail ~= nil then T.ok(false, first_fail) end
		T.eq(op_ok, op_total, "all operational checks agree")
		T.eq(mem_ok, mem_total, "all membership checks agree")
	end)
end)
