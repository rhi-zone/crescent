-- lib/test/fuzz.lua
-- Corpus-based mutation fuzzer with optional coverage guidance.
--
-- API:
--   fuzz.run(fn, opts) -> result          -- run the fuzzer
--   fuzz.it(desc, fn, opts)               -- test-runner integration
--   fuzz.mutate(input, rng, corpus)       -- single mutation step (exposed for testing)
--
-- Modes:
--   "fast"   -- dumb random mutation (default, no debug.sethook overhead)
--   "guided" -- coverage-guided: prefer mutations that hit new branches (slower)
--
-- opts for fuzz.run:
--   seeds         = {"", ...}   initial corpus (default: {""})
--   iters         = 1000        total mutation iterations
--   mode          = "fast"      "fast" | "guided"
--   corpus_dir    = nil         load/save corpus entries to disk
--   expected_errs = {}          error message patterns that are NOT crashes
--   max_input_len = 4096        discard mutations longer than this
--   mutations_per = {1, 4}      [min, max] mutations applied per iteration
--   seed          = nil         PRNG seed (default: FUZZ_SEED env or os.time())
--   on_crash      = nil         callback(input, err) called on each crash
--   on_new_path   = nil         callback(input, count) called on new coverage (guided)
--
-- result:
--   { iters, crashes=[{input,err},...], unique_paths, corpus_size, seed }

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── PRNG (LCG, no bit.* dependency — mirrors gen.lua) ────────────────────────

local LCG_MOD = 2^32
local LCG_A   = 1664525
local LCG_C   = 1013904223

local function make_rng(seed)
	local state = math.floor(seed or os.time()) % LCG_MOD
	if state == 0 then state = 12345 end
	local rng = { seed = seed }
	function rng:next()
		state = (state * LCG_A + LCG_C) % LCG_MOD
		return state
	end
	function rng:float()      return self:next() / LCG_MOD end
	function rng:int(lo, hi)
		if lo >= hi then return lo end
		return lo + (self:next() % (hi - lo + 1))
	end
	function rng:bool()       return self:next() % 2 == 0 end
	function rng:pick(t)      return t[1 + (self:next() % #t)] end
	return rng
end

-- ── Byte manipulation helpers ─────────────────────────────────────────────────

-- Flip bit bit_idx (0-7) in byte value b (portable, no bit library).
local function flip_bit(b, bit_idx)
	local pw = 2 ^ bit_idx
	local rem = b % (pw * 2)
	return rem >= pw and b - pw or b + pw
end

-- ── Interesting values ────────────────────────────────────────────────────────

local INTERESTING_BYTES = { 0, 1, 127, 128, 254, 255, 10, 13, 34, 39, 92, 47 }

local INTERESTING_STRINGS = {
	"", "\n", "\r\n", "--", "//", "\"\"", "''", "{}", "[]", "()",
	"0", "-1", "1", "9999999", "0x0", "0xff",
	"nil", "true", "false", "null",
	"do end", "return", "local",
}

-- ── Individual mutation strategies ───────────────────────────────────────────

--:: Rng = { seed: number, next: (self: Rng) -> number, float: (self: Rng) -> number, int: (self: Rng, lo: number, hi: number) -> number, bool: (self: Rng) -> boolean, pick: <T>(self: Rng, t: T[]) -> T }

--: (input: string, rng: Rng) -> string
local function mut_byte_flip(input, rng)
	if #input == 0 then return input end
	local pos     = rng:int(1, #input) --[[:! integer]]
	local b       = string.byte(input, pos) or 0
	local bit_idx = rng:int(0, 7)
	local nb      = flip_bit(b, bit_idx)
	return input:sub(1, pos-1) .. string.char(nb) .. input:sub(pos+1)
end

local function mut_byte_replace(input, rng)
	if #input == 0 then return input end
	local pos = rng:int(1, #input) --[[:! integer]]
	local nb  = rng:int(0, 255) --[[:! integer]]
	return input:sub(1, pos-1) .. string.char(nb) .. input:sub(pos+1)
end

local function mut_byte_insert(input, rng)
	local pos = rng:int(0, #input)
	local nb  = rng:int(0, 255)
	return input:sub(1, pos) .. string.char(nb) .. input:sub(pos+1)
end

local function mut_byte_delete(input, rng)
	if #input == 0 then return input end
	local pos = rng:int(1, #input) --[[:! integer]]
	return input:sub(1, pos-1) .. input:sub(pos+1)
end

local function mut_interesting_byte(input, rng)
	local pos = rng:int(0, #input)
	local b   = INTERESTING_BYTES[rng:int(1, #INTERESTING_BYTES)]
	return input:sub(1, pos) .. string.char(b) .. input:sub(pos+1)
end

--: (input: string, rng: Rng) -> string
local function mut_interesting_string(input, rng)
	local s   = INTERESTING_STRINGS[rng:int(1, #INTERESTING_STRINGS)] --[[:! string]]
	local pos = rng:int(0, #input) --[[:! integer]]
	return input:sub(1, pos) .. s .. input:sub(pos+1)
end

local function mut_block_repeat(input, rng)
	if #input < 2 then return input end
	local src_start = rng:int(1, #input)
	local src_len   = rng:int(1, math.min(16, #input - src_start + 1))
	local block     = input:sub(src_start, src_start + src_len - 1)
	local pos       = rng:int(0, #input)
	return input:sub(1, pos) .. block .. input:sub(pos+1)
end

local function mut_block_delete(input, rng)
	if #input < 2 then return input end
	local pos = rng:int(1, #input)
	local len = rng:int(1, math.min(16, #input - pos + 1))
	return input:sub(1, pos-1) .. input:sub(pos + len)
end

--: (input: string, other: string, rng: Rng) -> string
local function mut_splice(input, other, rng)
	if #input == 0 or #other == 0 then return input end
	local pivot1 = rng:int(1, #input) --[[:! integer]]
	local pivot2 = rng:int(1, #other) --[[:! integer]]
	return input:sub(1, pivot1) .. other:sub(pivot2)
end

local FAST_MUTATIONS = {
	mut_byte_flip, mut_byte_replace, mut_byte_insert, mut_byte_delete,
	mut_interesting_byte, mut_interesting_string, mut_block_repeat, mut_block_delete,
}

-- Apply one random mutation.  corpus is optional (used for splice).
--: (input: string, rng: Rng, corpus: string[] | nil) -> string
function M.mutate(input, rng, corpus)
	if corpus and #corpus > 1 and rng:float() < 0.15 then
		local cs = corpus --[[:! string[] ]]
		local other = cs[rng:int(1, #cs)]
		return mut_splice(input, other, rng)
	end
	local fn = FAST_MUTATIONS[rng:int(1, #FAST_MUTATIONS)] --[[:! (string, Rng) -> string]]
	return fn(input, rng)
end

-- Apply n mutations in sequence.
local function mutate_n(input, n, rng, corpus)
	for _ = 1, n do
		input = M.mutate(input, rng, corpus)
	end
	return input
end

-- ── Coverage tracking (guided mode) ──────────────────────────────────────────

-- Run fn(input) with debug.sethook line tracking.
-- global_bitmap: {"source:line" -> true} accumulated across all runs.
-- Returns ok, err, new_paths_count.
local function run_guided(fn, input, global_bitmap)
	local local_bitmap = {}
	debug.sethook(function(_, line)
		local info = debug.getinfo(2, "S")
		if info and info.source then
			local_bitmap[info.source .. ":" .. line] = true
		end
	end, "l")
	local ok, err = pcall(fn, input)
	(debug.sethook --[[: any]])()

	local new_paths = 0
	for k in pairs(local_bitmap) do
		if not global_bitmap[k] then
			global_bitmap[k] = true
			new_paths = new_paths + 1
		end
	end
	return ok, err, new_paths
end

-- ── Corpus persistence ────────────────────────────────────────────────────────

--: (dir: string) -> string[]
local function load_corpus_dir(dir)
	local corpus = {} --[[: string[] ]]
	local fh_ = io.popen("ls -1 " .. string.format("%q", dir) .. " 2>/dev/null")
	if not fh_ then return corpus end
	local fh = fh_ --[[: any]]
	for fname in fh:lines() do
		local fname_s = (fname --[[: any]]) --[[:! string]]
		if fname_s:match("%.corpus$") then
			local f = io.open(dir .. "/" .. fname_s, "rb")
			if f then
				corpus[#corpus+1] = (f:read("*a") --[[: any]]) --[[:! string]]
				f:close()
			end
		end
	end
	fh:close()
	return corpus
end

--: (dir: string, content: string, prefix: string | nil) -> nil
local function save_to_corpus(dir, content, prefix)
	-- Use a counter-based name derived from content length + rng noise.
	local tag = os.time() .. "_" .. tostring(math.random(0, 999999))
	local fname = dir .. "/" .. (prefix or "input") .. "_" .. tag .. ".corpus"
	local f = io.open(fname, "wb")
	if f then f:write(content); f:close() end
end

-- ── fuzz.run ──────────────────────────────────────────────────────────────────

function M.run(fn, opts)
	opts = opts or {}
	local seeds        = opts.seeds        or {""}
	local iters        = opts.iters        or 1000
	local mode         = opts.mode         or "fast"
	local corpus_dir   = opts.corpus_dir
	local expected_errs = opts.expected_errs or {}
	local max_len      = opts.max_input_len or 4096
	local mut_min      = opts.mutations_per and opts.mutations_per[1] or 1
	local mut_max      = opts.mutations_per and opts.mutations_per[2] or 4
	local prng_seed    = opts.seed
		or (tonumber(os.getenv and os.getenv("FUZZ_SEED") or nil))
		or os.time()

	local rng = make_rng(prng_seed)

	-- Build initial corpus.
	local corpus = {}
	for _, s in ipairs(seeds) do corpus[#corpus+1] = s end
	if corpus_dir then
		for _, s in ipairs(load_corpus_dir(corpus_dir --[[:! string]])) do
			corpus[#corpus+1] = s
		end
	end
	if #corpus == 0 then corpus[1] = "" end

	local crashes       = {}
	local unique_paths  = 0
	local global_bitmap = {}  -- only populated in guided mode
	local queue_idx     = 1

	for _ = 1, iters do
		-- Round-robin base selection.
		local base = corpus[queue_idx]
		queue_idx  = queue_idx % #corpus + 1

		-- Mutate.
		local n_muts = rng:int(mut_min, mut_max)
		local input  = mutate_n(base, n_muts, rng, corpus)
		if #input > max_len then input = input:sub(1, max_len) end

		-- Run target.
		local ok, err, new_paths
		if mode == "guided" then
			ok, err, new_paths = run_guided(fn, input, global_bitmap)
			if new_paths and new_paths > 0 then
				unique_paths = unique_paths + new_paths
				corpus[#corpus+1] = input
				if corpus_dir then save_to_corpus(corpus_dir --[[:! string]], input, "path") end
				if opts.on_new_path then (opts.on_new_path --[[:! (string, integer) -> any]])(input, new_paths) end
			end
		else
			ok, err = pcall(fn, input)
		end

		-- Crash detection.
		if not ok then
			local is_expected = false
			if type(err) == "string" then
				for _, pat in ipairs(expected_errs) do
					if err:find(pat) then
						is_expected = true; break
					end
				end
			end
			if not is_expected then
				crashes[#crashes+1] = { input = input, err = tostring(err) }
				if corpus_dir then save_to_corpus(corpus_dir --[[:! string]], input, "crash") end
				if opts.on_crash then (opts.on_crash --[[:! (string, any) -> any]])(input, err) end
			end
		end
	end

	return {
		iters        = iters,
		crashes      = crashes,
		unique_paths = unique_paths,
		corpus_size  = #corpus,
		seed         = prng_seed,
	}
end

-- ── fuzz.it ───────────────────────────────────────────────────────────────────

-- Register a fuzz test with the assertion framework.
-- Fails the test if any unexpected crash is found.
--
-- opts: same as fuzz.run, plus:
--   expect_no_crashes = true  (default) — fail if any crash found
function M.it(desc, fn, opts)
	opts = opts or {}
	local expect_no_crashes = opts.expect_no_crashes
	if expect_no_crashes == nil then expect_no_crashes = true end

	local T = require("lib.test.assert")
	T.it(desc, function()
		local result = M.run(fn, opts)
		local mode   = opts.mode or "fast"

		if expect_no_crashes and #result.crashes > 0 then
			local c   = result.crashes[1]
			local msg = string.format(
				"fuzz: crash found after %d iters  (seed=%d, replay: FUZZ_SEED=%d)\n"
					.. "  input: %q\n  error: %s",
				result.iters, result.seed, result.seed, c.input, c.err
			)
			error(msg, 2)
		end

		-- Report summary as an assertion label (always passes here).
		local summary
		if mode == "guided" then
			summary = string.format(
				"fuzz ok: %d iters, %d corpus, %d unique paths, %d crashes",
				result.iters, result.corpus_size, result.unique_paths, #result.crashes
			)
		else
			summary = string.format(
				"fuzz ok: %d iters, %d corpus, %d crashes",
				result.iters, result.corpus_size, #result.crashes
			)
		end

		local assert_mod = require("lib.test.assert")
		assert_mod.ok(true, summary)
	end)
end

return M
