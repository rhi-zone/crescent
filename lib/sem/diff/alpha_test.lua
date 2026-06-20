-- lib/sem/diff/alpha_test.lua
-- Loop-α: the differential harness validating our executable spec against REAL
-- Lua interpreters, PER VERSION (docs/typechecker-formal-semantics.md §2). For
-- each generated v1-subset surface program and each available interpreter:
--   (a) lower (under the version's profile) → run → observe   (our spec)
--   (b) print → temp .lua → shell the interpreter → capture → observe   (real)
-- and assert the two observations AGREE (observe.agree, admissible-set aware).
--
-- INTERPRETER MATRIX (S2): vendored LuaJIT 5.1 (ALWAYS present) plus PUC
--   lua5.1 / lua5.2 / lua5.3 / lua5.4 when on PATH (nix develop / CI). Each PUC
--   binary is PROBED at runtime via the injected popen cap; an absent binary is
--   SKIPPED (reported, never a failure) so `bin/cr test lib/sem/` stays green on
--   a BARE clone with only the vendored LuaJIT.
--
-- THE PROVING DELTA (5.3/5.4 int/float split): besides agreement, we assert
-- EXPECTED cross-version DIVERGENCES positively (a small known-delta table), so a
-- regression that collapsed the version-parametricity into a single behaviour is
-- caught — agreement alone is not enough.
--
-- CAPS-FIRST: interpreter binaries are invoked through an INJECTED popen cap (and
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
local observe  = require("lib.sem.diff.observe")
local arbprog  = require("lib.sem.diff.arb_program")
local gen      = require("lib.test.gen")

--:: require "lib.sem.lang.lua.lower"
--:: require "lib.sem.run"
--:: require "lib.caps.types"

--:: Rng = { seed: number, next: (self: Rng) -> number, float: (self: Rng) -> number, int: (self: Rng, lo: integer, hi: integer) -> integer, bool: (self: Rng) -> boolean, pick: <T>(self: Rng, t: T[]) -> T }

-- Injected I/O caps (the ONLY place globals are read; the harness body uses these).
--:: ExecCaps = { popen: POpenFn, open: OpenFn, remove: RemoveFn, tmpname: TmpnamFn }

-- A version entry: the spec Profile + the real interpreter command to drive it.
--:: VersionEntry = { profile: Profile, cmd: string }

-- locate the vendored luajit (bin/luajit dispatches to the platform binary).
local LUAJIT = "./bin/luajit"

-- ── interpreter probing (caps-first) ─────────────────────────────────────────
-- Probe whether a command runs at all by asking it to print a sentinel. Returns
-- true iff the binary exists and executes. The vendored LuaJIT is assumed present
-- (it is the runtime); PUC binaries are probed and skipped if absent.
--: (ExecCaps, string) -> boolean
local function probe(caps, cmd)
	local out = exec.run(cmd, { "-e", "io.write('crsem-probe')" },
		{ popen = caps.popen, stderr = "discard" })
	if out == nil then return false end
	return out:find("crsem-probe", 1, true) ~= nil
end

-- ── real-side execution ──────────────────────────────────────────────────────
-- Build a self-contained Lua chunk that runs the printed program body, captures
-- its return tuple, and prints ONE canonical observation line ("OK <shape>" or
-- "FAULT"). The shape tokens match observe.render_value exactly.
--
-- The number renderer is VERSION-FAITHFUL: where `math.type` exists (5.3/5.4) it
-- renders an integer as "%d" and a float via the version's own tostring (which
-- shows "3.0" for integral floats), so the int/float distinction is observable;
-- where it does not (5.1/5.2/LuaJIT) every number is the single double form.
--: (string) -> string
local function wrap_real(body_src)
	local render = [[
local has_mathtype = (type(math.type) == "function")
local function render(v)
  local t = type(v)
  if t == "number" then
    if v ~= v then return "n:nan" end
    if v == math.huge then return "n:inf" end
    if v == -math.huge then return "n:-inf" end
    if has_mathtype then
      if math.type(v) == "integer" then
        return "n:" .. string.format("%d", v)
      end
      -- float: use the version's own tostring (shows "3.0" for integral floats)
      return "n:" .. tostring(v)
    end
    -- single-double versions: integral renders "%d", else "%.14g".
    if v == math.floor(v) and math.abs(v) < 1e15 then return "n:" .. string.format("%d", v) end
    return "n:" .. string.format("%.14g", v)
  elseif t == "string" then return "s:" .. v
  elseif t == "boolean" then return v and "b:true" or "b:false"
  elseif t == "nil" then return "nil"
  elseif t == "table" then return "table"
  else return "function" end
end
]]
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

-- run a real interpreter on a program body, returning its observation.
--: (ExecCaps, string, string) -> Observation
local function run_real(caps, cmd, body_src)
	local path = caps.tmpname() .. ".sem.lua"
	local fh = caps.open(path, "w")
	if fh == nil then error("alpha: cannot open temp file " .. path) end
	fh:write(wrap_real(body_src))
	fh:close()
	local out, err = exec.run(cmd, { path }, { popen = caps.popen, stderr = "discard" })
	caps.remove(path)
	if out == nil then
		local _ = err
		return { tag = "fault", shape = "" }
	end
	local line = "FAULT"
	for l in out:gmatch("[^\n]+") do line = l end
	return observe.observe_real(line)
end

-- ── one trial against one version ────────────────────────────────────────────
-- Returns (ok, spec_obs, real_obs). ok = observations agree.
--: (ExecCaps, VersionEntry, SS[]) -> (boolean, Observation, Observation)
local function trial(caps, entry, prog)
	local control = lower.lower_program(entry.profile.va, prog) --: Stmt[]
	local res = run.run(entry.profile, control, 200000) --: RunResult
	local spec_obs = observe.observe_spec(entry.profile.va, res)
	local body_src = printer.print_program(prog)
	local real_obs = run_real(caps, entry.cmd, body_src)
	return observe.agree(spec_obs, real_obs), spec_obs, real_obs
end

-- ── the harness ──────────────────────────────────────────────────────────────
T.describe("sem Loop-alpha: spec vs real Lua interpreters (per version)", function()
	-- caps-first: wire real caps here; the harness body uses only `caps`.
	local caps = {
		popen = io.popen, open = io.open, remove = os.remove, tmpname = os.tmpname,
	} --[[: ExecCaps]]

	-- The candidate version matrix: spec profile + real interpreter command.
	-- The vendored LuaJIT is ALWAYS available (the runtime); PUC commands are
	-- probed below.
	local candidates = {
		{ profile = profile.luajit51, cmd = LUAJIT, always = true },
		{ profile = profile.lua51, cmd = "lua5.1", always = false },
		{ profile = profile.lua52, cmd = "lua5.2", always = false },
		{ profile = profile.lua53, cmd = "lua5.3", always = false },
		{ profile = profile.lua54, cmd = "lua5.4", always = false },
	} --[[: { profile: Profile, cmd: string, always: boolean }[] ]]

	-- resolve which versions are actually runnable here.
	local present = {} --[[: VersionEntry[] ]]
	local skipped = {} --[[: { [integer]: string } ]]
	for i = 1, #candidates do
		local c = candidates[i]
		if c ~= nil then
			if c.always or probe(caps, c.cmd) then
				present[#present + 1] = { profile = c.profile, cmd = c.cmd }
			else
				skipped[#skipped + 1] = c.profile.name
			end
		end
	end

	-- report the matrix once (visible in test output).
	local names = {} --[[: { [integer]: string } ]]
	for i = 1, #present do names[i] = present[i].profile.name end
	print("  [Loop-alpha] versions present: " .. table.concat(names, ", ")
		.. (#skipped > 0 and ("  | skipped (binary absent): " .. table.concat(skipped, ", ")) or ""))

	-- ── (1) per-version agreement on generated programs ───────────────────────
	T.it("generated v1-subset programs agree per version (spec vs real)", function()
		local seed = os.time() --: number
		local seed_env = os.getenv("PROP_SEED")
		if seed_env ~= nil then
			local parsed = tonumber(seed_env)
			if parsed ~= nil then seed = parsed end
		end

		local trials = 120
		for vi = 1, #present do
			local entry = present[vi]
			-- a fresh RNG per version so every version sees the SAME program stream.
			local rng = gen.make_rng(math.floor(seed)) --: Rng
			local agreed = 0
			local first_fail --: SS[] | nil
			local first_fail_spec --: Observation | nil
			local first_fail_real --: Observation | nil
			for i = 1, trials do
				local sz = math.min(i, 40)
				local prog, _c = arbprog.arb.generate(rng, sz)
				local ok, spec_obs, real_obs = trial(caps, entry, prog)
				if ok then
					agreed = agreed + 1
				elseif first_fail == nil then
					first_fail = prog
					first_fail_spec = spec_obs
					first_fail_real = real_obs
				end
			end

			if first_fail ~= nil then
				local cur = first_fail --: SS[]
				local steps = 0
				while steps < 200 do
					local iter = arbprog.arb.shrink(cur, nil)
					local found = false
					while true do
						local cand_ = iter()
						if cand_ == nil then break end
						local cand = cand_ --[[: SS[] ]]
						local ok2 = trial(caps, entry, cand)
						if not ok2 then cur = cand; found = true; steps = steps + 1; break end
					end
					if not found then break end
				end
				local _, sobs, robs = trial(caps, entry, cur)
				local witness_src = printer.print_program(cur)
				T.ok(false,
					"Loop-alpha DIVERGENCE on " .. entry.profile.name
					.. " (replay: PROP_SEED=" .. seed .. ")\n"
					.. "  agreed before failure: " .. agreed .. "/" .. trials .. "\n"
					.. "  minimal witness (" .. steps .. " shrink steps):\n" .. witness_src
					.. "  spec observation: " .. observe.show(sobs) .. "\n"
					.. "  real observation: " .. observe.show(robs) .. "\n"
					.. "  (first-fail spec: " .. observe.show(first_fail_spec or sobs)
					.. ", real: " .. observe.show(first_fail_real or robs) .. ")")
			end

			print("  [Loop-alpha] " .. entry.profile.name .. ": "
				.. agreed .. "/" .. trials .. " agreed")
			T.ok(agreed == trials,
				entry.profile.name .. ": all " .. trials .. " programs agreed (got " .. agreed .. ")")
		end
	end)

	-- ── (2) expected cross-version DELTAS asserted positively ─────────────────
	-- A small fragment whose observable result DIFFERS across number models,
	-- proving the version-parametricity is real (not just "no disagreement").
	-- Each row: a surface program + the expected SPEC observation per model.
	-- We check the SPEC here (deterministic + the proof subject); where a real
	-- interpreter for the version is present we ALSO confirm the real side agrees.
	T.it("known cross-version deltas hold (int/float split is real)", function()
		-- num literal helpers.
		--: (number) -> SX
		local function n(x)
			local e = { x = "num", n = x } --[[: SX]]
			return e
		end
		--: (number) -> SX
		local function f(x)
			local e = { x = "num", n = x, float = true } --[[: SX]]
			return e
		end
		--: (string, SX, SX) -> SX
		local function bin(op, a, b)
			local e = { x = "binop", op = op, a = a, b = b } --[[: SX]]
			return e
		end
		--: (SX[]) -> SS[]
		local function ret(es)
			local s = { s = "return", exprs = es } --[[: SS]]
			local prog = { s } --[[: SS[] ]]
			return prog
		end

		-- The delta table. Each row carries a program + an EXPECTED SPEC OBSERVATION
		-- token per profile name, where the token is either a value shape ("n:2.0")
		-- or the literal "FAULT" (used for `//` under 5.1/5.2/LuaJIT, where the
		-- operator does not exist → stuck). These are POSITIVE regression assertions
		-- that the version-parametricity is real: each row that lists different
		-- tokens across profiles is a concrete cross-version divergence the fragment
		-- exercises, not just an absence of disagreement.
		--:: Delta = { name: string, prog: SS[], exp: { [string]: string } }
		local deltas = {
			-- 4 / 2 : `/` ALWAYS yields a float in 5.3/5.4 → "2.0"; single-double → "2".
			{ name = "div always float: 4/2", prog = ret({ bin("div", n(4), n(2)) }),
				exp = { luajit51 = "n:2", lua51 = "n:2", lua52 = "n:2", lua53 = "n:2.0", lua54 = "n:2.0" } },
			-- 2 + 3 : integer in dual, double in single; same rendered token "5".
			{ name = "int add: 2+3", prog = ret({ bin("add", n(2), n(3)) }),
				exp = { luajit51 = "n:5", lua51 = "n:5", lua52 = "n:5", lua53 = "n:5", lua54 = "n:5" } },
			-- 5 // 2 : `//` is a SYNTAX ERROR in 5.1/5.2/LuaJIT (→ FAULT); in 5.3/5.4 it
			-- floor-divides two integers to the integer 2. THE op-availability delta.
			{ name = "idiv: 5//2", prog = ret({ bin("idiv", n(5), n(2)) }),
				exp = { luajit51 = "FAULT", lua51 = "FAULT", lua52 = "FAULT", lua53 = "n:2", lua54 = "n:2" } },
			-- float literal 3.0 : a FLOAT in 5.3/5.4 → "3.0"; a plain double in single →
			-- "3". The clean observable int/float divergence.
			{ name = "float literal 3.0", prog = ret({ f(3) }),
				exp = { luajit51 = "n:3", lua51 = "n:3", lua52 = "n:3", lua53 = "n:3.0", lua54 = "n:3.0" } },
			-- float + int promotes to float in dual: 2.0 + 3 = 5.0 → "5.0"; single → "5".
			{ name = "float+int promotes: 2.0+3", prog = ret({ bin("add", f(2), n(3)) }),
				exp = { luajit51 = "n:5", lua51 = "n:5", lua52 = "n:5", lua53 = "n:5.0", lua54 = "n:5.0" } },
		} --[[: Delta[] ]]

		--: (Profile) -> VersionEntry | nil
		local function entry_for(prof)
			for i = 1, #present do
				if present[i].profile.name == prof.name then return present[i] end
			end
			return nil
		end

		-- the full profile list to assert the spec against (ALL five, regardless of
		-- which real interpreters are present — the spec is deterministic).
		local profs = profile.all --: Profile[]

		local any_divergence = false
		for di = 1, #deltas do
			local d = deltas[di]
			if d ~= nil then
				-- a row diverges if it lists at least two distinct expected tokens.
				local seen --: string | nil
				for _name, tok in pairs(d.exp) do
					if seen == nil then seen = tok elseif tok ~= seen then any_divergence = true end
				end
				for pi = 1, #profs do
					local prof = profs[pi]
					if prof ~= nil then
						local want = d.exp[prof.name]
						if want ~= nil then
							local ctrl = lower.lower_program(prof.va, d.prog) --: Stmt[]
							local res = run.run(prof, ctrl, 50000) --: RunResult
							local obs = observe.observe_spec(prof.va, res)
							-- "FAULT" expectation matches a spec fault observation; any other
							-- expectation is an exact value-shape match.
							if want == "FAULT" then
								T.eq(obs.tag, "fault")
							else
								T.eq(obs.tag, "value")
								T.eq(obs.shape, want)
							end
							-- cross-check the REAL interpreter for this version when present.
							local entry = entry_for(prof)
							if entry ~= nil then
								local ro = run_real(caps, entry.cmd, printer.print_program(d.prog))
								T.ok(observe.agree(obs, ro),
									d.name .. " @ " .. prof.name .. ": real agrees with spec "
									.. "(spec " .. observe.show(obs) .. " real " .. observe.show(ro) .. ")")
							end
						end
					end
				end
			end
		end
		T.ok(any_divergence, "at least one delta row genuinely diverges across profiles")
	end)
end)
