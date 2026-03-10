-- lib/test/prop.lua
-- Property-based (QuickCheck-style) test runner.
--
-- Usage:
--   local prop = require("lib.test.prop")
--   local gen  = require("lib.test.gen")
--
--   prop.it("reversing twice is identity", gen.list(gen.int(-100, 100)), function(xs)
--       local rev = function(t)
--           local r = {} for i = #t, 1, -1 do r[#r+1] = t[i] end return r
--       end
--       local result = rev(rev(xs))
--       assert(#result == #xs)
--       for i = 1, #xs do assert(result[i] == xs[i]) end
--   end)
--
-- Seed override: set PROP_SEED env var for deterministic replay.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local gen_mod = require("lib.test.gen")

local M  = {}
M.gen    = gen_mod   -- re-export for convenience

local DEFAULT_TRIALS    = 100
local DEFAULT_MAX_SHRINK = 200

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function get_default_seed()
	local s = os.getenv and os.getenv("PROP_SEED")
	if s then
		local n = tonumber(s)
		if n then return math.floor(n) end
	end
	return os.time()
end

-- Human-readable representation of a value (for error messages).
local function display(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "string"  then return string.format("%q", v) end
	if t == "number"  then
		if v == math.floor(v) and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		return tostring(v)
	end
	if t == "boolean" then return tostring(v) end
	if t == "nil"     then return "nil" end
	if t ~= "table"   then return tostring(v) end
	if depth > 2      then return "{...}" end

	local parts  = {}
	local is_arr = #v > 0
	if is_arr then
		for i = 1, math.min(#v, 8) do
			parts[#parts+1] = display(v[i], depth + 1)
		end
		if #v > 8 then parts[#parts+1] = "... (" .. #v .. " items)" end
		return "{" .. table.concat(parts, ", ") .. "}"
	else
		local n = 0
		for k, val in pairs(v) do
			n = n + 1
			if n > 6 then parts[#parts+1] = "..."; break end
			parts[#parts+1] = tostring(k) .. "=" .. display(val, depth + 1)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
end

-- Display a tuple (array of args) as "v1, v2, ..."
local function display_tuple(args)
	if #args == 1 then return display(args[1]) end
	local parts = {}
	for i, v in ipairs(args) do parts[i] = display(v) end
	return "(" .. table.concat(parts, ", ") .. ")"
end

-- ── Core shrink loop ──────────────────────────────────────────────────────────

-- Given a generator and a failing value, find the minimal failing example.
-- check_fn(value) should throw on failure and return normally on pass.
local function do_shrink(shrink_fn, failing, check_fn, max_steps)
	local current = failing
	local steps   = 0
	while steps < max_steps do
		local candidates = shrink_fn(current)
		if not candidates or #candidates == 0 then break end
		local found = false
		for _, candidate in ipairs(candidates) do
			local ok = pcall(check_fn, candidate)
			if not ok then
				current = candidate
				found   = true
				steps   = steps + 1
				break
			end
		end
		if not found then break end
	end
	return current, steps
end

-- ── prop.check ────────────────────────────────────────────────────────────────

-- Run N trials of a property.
--
-- gen_arg: a single generator, or an array of generators (for multiple args).
-- fn:      property function; should assert/error on failure.
-- opts:    { trials=100, seed=number, max_shrink=200 }
--
-- Returns: ok (bool), info (nil on success, table on failure).
-- info = { trial, seed, original, shrunk, shrink_steps, err }
function M.check(desc, gen_arg, fn, opts)
	opts        = opts or {}
	local trials    = opts.trials    or DEFAULT_TRIALS
	local seed      = opts.seed      or get_default_seed()
	local max_shrink = opts.max_shrink or DEFAULT_MAX_SHRINK

	local rng = gen_mod.make_rng(seed)

	-- Normalise: single generator vs array of generators.
	-- We always work internally with a "tuple" generator that returns an array.
	local tup_gen
	if type(gen_arg) == "table" and gen_arg.generate then
		-- Single generator → wrap in a 1-tuple
		tup_gen = gen_mod.tuple({gen_arg})
	elseif type(gen_arg) == "table" and gen_arg[1] and gen_arg[1].generate then
		-- Array of generators
		tup_gen = gen_mod.tuple(gen_arg)
	else
		error("prop.check: expected a generator or array of generators, got " .. type(gen_arg))
	end

	-- Size increases with trial number (capped at 100).
	local function run(args) fn(unpack(args)) end

	for trial = 1, trials do
		local size = math.min(trial, 100)
		local args = tup_gen.generate(rng, size)
		local ok, err = pcall(run, args)
		if not ok then
			-- Shrink
			local shrunk, shrink_steps = do_shrink(
				tup_gen.shrink, args, run, max_shrink
			)
			return false, {
				desc         = desc,
				trial        = trial,
				seed         = seed,
				original     = args,
				shrunk       = shrunk,
				shrink_steps = shrink_steps,
				err          = tostring(err),
			}
		end
	end

	return true, nil
end

-- ── prop.it ───────────────────────────────────────────────────────────────────

-- Run a property as a named test block (integrates with lib/test/assert.lua).
-- Failures appear in the test runner output just like any it() failure.
function M.it(desc, gen_arg, fn, opts)
	local assert_mod = require("lib.test.assert")
	assert_mod.it(desc, function()
		local ok, info = M.check(desc, gen_arg, fn, opts)
		if not ok then
			local lines = {
				"property falsified after " .. info.trial
					.. " test" .. (info.trial == 1 and "" or "s")
					.. "  (seed=" .. info.seed .. ", replay: PROP_SEED=" .. info.seed .. ")",
				"  input:   " .. display_tuple(info.original),
				"  shrunk:  " .. display_tuple(info.shrunk)
					.. "  (" .. info.shrink_steps .. " step"
					.. (info.shrink_steps == 1 and "" or "s") .. ")",
				"  error:   " .. info.err,
			}
			error(table.concat(lines, "\n"), 2)
		end
	end)
end

-- ── prop.assert ───────────────────────────────────────────────────────────────

-- Run a property inline (not inside it()).  Throws on failure.
-- Useful inside existing it() blocks:
--   assert.it("my test", function()
--     prop.assert("add commutes", gen.tuple({gen.int(0,10), gen.int(0,10)}), function(xs)
--       assert(xs[1] + xs[2] == xs[2] + xs[1])
--     end)
--   end)
function M.assert(desc, gen_arg, fn, opts)
	local ok, info = M.check(desc, gen_arg, fn, opts)
	if not ok then
		local msg = "property falsified after " .. info.trial .. " test(s)"
			.. "  (seed=" .. info.seed .. ")\n"
			.. "  input:   " .. display_tuple(info.original) .. "\n"
			.. "  shrunk:  " .. display_tuple(info.shrunk) .. "\n"
			.. "  error:   " .. info.err
		error(msg, 2)
	end
end

return M
