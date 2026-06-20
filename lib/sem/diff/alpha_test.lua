-- lib/sem/diff/alpha_test.lua
-- Loop-α: the differential harness validating our executable spec against REAL
-- LuaJIT, per docs/typechecker-formal-semantics.md. For each generated v1-subset
-- surface program:
--   (a) lower → run → observe   (our spec, lib/sem/run.lua + observe.lua)
--   (b) print → temp .lua → shell `bin/luajit` → capture → observe  (real)
-- and assert the two observations AGREE (observe.agree, admissible-set aware).
-- On a mismatch we shrink to a minimal witness and report the seed for replay,
-- mirroring op_sem_independent_parity_test.lua's divergence-reporting style.
--
-- CAPS-FIRST: the luajit binary is invoked through an INJECTED popen cap (and
-- open/remove/tmpname for the temp file), never reached from `io`/`os` directly
-- in the harness logic. The test wires the real caps at the top; a missing cap
-- errors rather than silently falling back.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local exec     = require("lib.exec")
local lower    = require("lib.sem.lang.lua.lower")
local printer  = require("lib.sem.lang.lua.print")
local run      = require("lib.sem.run")
local profile  = require("lib.sem.profile")
local value    = require("lib.sem.value")
local observe  = require("lib.sem.diff.observe")
local arbprog  = require("lib.sem.diff.arb_program")
local gen      = require("lib.test.gen")

--:: require "lib.sem.lang.lua.lower"
--:: require "lib.sem.run"
--:: require "lib.caps.types"

--:: Rng = { seed: number, next: (self: Rng) -> number, float: (self: Rng) -> number, int: (self: Rng, lo: integer, hi: integer) -> integer, bool: (self: Rng) -> boolean, pick: <T>(self: Rng, t: T[]) -> T }

-- Injected I/O caps (the ONLY place globals are read; the harness body uses these).
--:: ExecCaps = { popen: POpenFn, open: OpenFn, remove: RemoveFn, tmpname: TmpnamFn, luajit: string }

-- locate the vendored luajit (bin/luajit dispatches to the platform binary).
local LUAJIT = "./bin/luajit"

-- ── real-side execution ──────────────────────────────────────────────────────
-- Build a self-contained Lua chunk that runs the printed program body, captures
-- its return tuple, and prints ONE canonical observation line ("OK <shape>" or
-- "FAULT"). The shape tokens match observe.render_value exactly.
--: (string) -> string
local function wrap_real(body_src)
	-- The render function in the harnessed chunk mirrors observe.render_value.
	local render = [[
local function render(v)
  local t = type(v)
  if t == "number" then
    if v ~= v then return "n:nan" end
    if v == math.huge then return "n:inf" end
    if v == -math.huge then return "n:-inf" end
    if v == math.floor(v) and math.abs(v) < 1e15 then return "n:" .. string.format("%d", v) end
    return "n:" .. string.format("%.14g", v)
  elseif t == "string" then return "s:" .. v
  elseif t == "boolean" then return v and "b:true" or "b:false"
  elseif t == "nil" then return "nil"
  elseif t == "table" then return "table"
  else return "function" end
end
]]
	-- Capture the EXACT return arity (including trailing nils being dropped, to
	-- match the spec's tuple which carries exactly #values). `select('#', ...)`
	-- inside the result-collector gives the true arity from pcall's varargs.
	local chunk = render
		.. "local function __body(...)\n" .. body_src .. "end\n"
		.. "local function collect(ok, ...)\n"
		.. "  if not ok then io.write('FAULT\\n') return end\n"
		.. "  local n = select('#', ...)\n"
		.. "  local vs = {...}\n"
		.. "  local parts = {}\n"
		.. "  for i=1,n do parts[i] = render(vs[i]) end\n"
		.. "  io.write('OK ' .. table.concat(parts, ',') .. '\\n')\n"
		.. "end\n"
		.. "collect(pcall(function() return __body() end))\n"
	return chunk
end

-- run the real LuaJIT on a program body, returning its observation.
--: (ExecCaps, string) -> Observation
local function run_real(caps, body_src)
	local path = caps.tmpname() .. ".sem.lua"
	local fh = caps.open(path, "w")
	if fh == nil then error("alpha: cannot open temp file " .. path) end
	fh:write(wrap_real(body_src))
	fh:close()
	local out, err = exec.run(caps.luajit, { path }, { popen = caps.popen, stderr = "discard" })
	caps.remove(path)
	if out == nil then
		-- a non-zero exit / crash from LuaJIT is itself a fault observation.
		local _ = err
		return { tag = "fault", shape = "" }
	end
	-- take the LAST non-empty line as the observation (defensive against stray output).
	local line = "FAULT"
	for l in out:gmatch("[^\n]+") do line = l end
	return observe.observe_real(line)
end

-- ── one trial ────────────────────────────────────────────────────────────────
-- Returns (ok, spec_obs, real_obs). ok = observations agree.
--: (ExecCaps, SS[]) -> (boolean, Observation, Observation)
local function trial(caps, prog)
	local control = lower.lower_program(prog) --: Stmt[]
	local res = run.run(profile.luajit51, control, 200000) --: RunResult
	local spec_obs = observe.observe_spec(value.luajit51, res)
	local body_src = printer.print_program(prog)
	local real_obs = run_real(caps, body_src)
	return observe.agree(spec_obs, real_obs), spec_obs, real_obs
end

-- ── the test ─────────────────────────────────────────────────────────────────
T.describe("sem Loop-alpha: spec vs real LuaJIT", function()
	T.it("generated v1-subset programs agree (spec step vs vendored LuaJIT)", function()
		-- caps-first: wire real caps here; the harness body uses only `caps`.
		local caps = {
			popen = io.popen, open = io.open, remove = os.remove,
			tmpname = os.tmpname, luajit = LUAJIT,
		} --[[: ExecCaps]]

		local seed = os.time() --: number
		local seed_env = os.getenv("PROP_SEED")
		if seed_env ~= nil then
			local parsed = tonumber(seed_env)
			if parsed ~= nil then seed = parsed end
		end
		local rng = gen.make_rng(math.floor(seed)) --: Rng

		local trials = 200
		local agreed = 0
		local first_fail --: SS[] | nil
		local first_fail_spec --: Observation | nil
		local first_fail_real --: Observation | nil

		for i = 1, trials do
			local sz = math.min(i, 60)
			local prog, _c = arbprog.arb.generate(rng, sz)
			local ok, spec_obs, real_obs = trial(caps, prog)
			if ok then
				agreed = agreed + 1
			elseif first_fail == nil then
				first_fail = prog
				first_fail_spec = spec_obs
				first_fail_real = real_obs
			end
		end

		if first_fail ~= nil then
			-- shrink to a minimal witness using the generator's shrinker.
			local cur = first_fail --: SS[]
			local steps = 0
			while steps < 200 do
				local iter = arbprog.arb.shrink(cur, nil)
				local found = false
				while true do
					local cand_ = iter()
					if cand_ == nil then break end
					local cand = cand_ --[[: SS[] ]]
					local ok2 = trial(caps, cand)
					if not ok2 then cur = cand; found = true; steps = steps + 1; break end
				end
				if not found then break end
			end
			local _, sobs, robs = trial(caps, cur)
			local witness_src = printer.print_program(cur)
			T.ok(false,
				"Loop-alpha DIVERGENCE (replay: PROP_SEED=" .. seed .. ")\n"
				.. "  agreed before failure: " .. agreed .. "/" .. trials .. "\n"
				.. "  minimal witness (" .. steps .. " shrink steps):\n" .. witness_src
				.. "  spec observation: " .. observe.show(sobs) .. "\n"
				.. "  real observation: " .. observe.show(robs) .. "\n"
				.. "  (first-fail spec: " .. observe.show(first_fail_spec or sobs)
				.. ", real: " .. observe.show(first_fail_real or robs) .. ")")
		end

		T.ok(agreed == trials,
			"all " .. trials .. " generated programs agreed (got " .. agreed .. ")")
	end)
end)
