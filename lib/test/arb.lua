-- lib/test/arb.lua
-- Property-based testing with integrated shrinking (fast-check context approach).
--
-- WHY NOT HEDGEHOG (rose trees)?
-- Hedgehog solves the same problem: shrinking works correctly through map/filter
-- because the shrink tree is threaded through composition.  It is the right
-- design for Haskell: lazy evaluation makes unevaluated thunks nearly free, and
-- purity makes context-threading awkward.  In Lua both assumptions flip: there
-- is no laziness (a {value, thunk} node and its closure cost real heap space on
-- every trial), and mutable/opaque context is idiomatic.  Building the rose tree
-- eagerly would be worse than QuickCheck; building it lazily just reinvents the
-- context approach with extra indirection.
--
-- WHY NOT QUICKCHECK (lib/test/prop.lua)?
-- gen.map(g, fn) cannot shrink — there is no pre-image, so shrink returns {}.
-- Composed generators (AST builders, nested records, mapped types) lose all
-- shrink information.  Use prop.lua when your generators are primitives and
-- direct lists.  Use this module when you map, filter, or chain.
--
-- THIS MODULE: fast-check "context-carrying" approach.
--   generate(rng, size) -> val, ctx
--   shrink(val, ctx)    -> iter     where iter() -> val, ctx | nil
--
-- ctx is opaque metadata produced at generation time and consumed by the
-- shrinker.  The shrinker never re-runs the generator; it only needs ctx.
-- For map(a, fn): ctx = {pre_val, pre_ctx}.  shrink delegates to a.shrink,
-- then re-applies fn.  Correct shrinking, no rose tree.
--
-- HAPPY-PATH PERFORMANCE GOAL: no compromises.
-- On a passing trial the test function returns and the value is discarded.
-- shrink() is never called.  Therefore:
--   * shrink() may allocate freely — it only runs on failure (rare).
--   * generate() for primitive types (int, float, bool, byte, constant) must
--     return val, nil — zero allocation beyond the value itself.
--   * generate() for composed types (map, one_of, sized) allocates exactly one
--     context table.  This is unavoidable: without storing the pre-image we
--     cannot shrink later.  Avoid composing primitives unnecessarily when
--     prop.lua would suffice.
--   * generate() for collections (array, tuple, record) allocates the output
--     collection (which any generator must do) plus a ctxs table only when at
--     least one element has a non-nil context.  Arrays of int/bool/float carry
--     ctx = nil — no second allocation.
--
-- LIMITATION: chain (monadic bind) cannot shrink the first value through the
-- dependency — doing so requires an RNG at shrink time.  Only the second value
-- is shrunk.  If full chain shrinking matters, restructure with tuple + filter.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local gen_mod = require("lib.test.gen")  -- for make_rng only

local M = {}

-- ── Shared sentinel ──────────────────────────────────────────────────────────

-- Returned by shrink() when there is nothing to shrink.
-- Single shared closure; never allocates.
local EMPTY_ITER = function() return nil end

-- ── Int shrink iterator ───────────────────────────────────────────────────────
--
-- Emits candidates in order: most-shrunk first (closest to target), then
-- progressively less shrunk.  Binary-search by halving the gap each step.
--
-- Example: val=10, target=0 → [0, 5, 8, 9]
--          val=-7, target=0 → [0, -4, -6]
--
-- Allocates one closure per shrink call (off the hot path).

local function int_shrink_iter(val, target)
	if val == target then return EMPTY_ITER end
	local diff = val - target   -- positive or negative, never 0
	return function()
		if diff == 0 then return nil end
		local candidate = val - diff
		-- Halve diff toward 0 (floor for positive, ceil for negative).
		diff = diff > 0 and math.floor(diff / 2) or math.ceil(diff / 2)
		return candidate, nil
	end
end

-- ── Primitives ────────────────────────────────────────────────────────────────
-- All primitives produce ctx = nil.  generate() allocates nothing.

function M.int(lo, hi)
	assert(lo <= hi, "arb.int: lo > hi")
	local target = math.max(lo, math.min(hi, 0))
	return {
		generate = function(rng, _) return rng:int(lo, hi), nil end,
		shrink   = function(v, _)   return int_shrink_iter(v, target) end,
	}
end

M.uint = M.int(0, 2^31 - 1)
M.byte = M.int(0, 255)

function M.float(lo, hi)
	lo = lo or 0.0; hi = hi or 1.0
	local target = math.max(lo, math.min(hi, 0.0))
	return {
		generate = function(rng, _) return lo + rng:float() * (hi - lo), nil end,
		shrink   = function(v, _)
			if math.abs(v - target) < 1e-12 then return EMPTY_ITER end
			local mid  = (v + target) / 2
			local done = false
			return function()
				if done then return nil end; done = true
				return mid, nil
			end
		end,
	}
end

M.bool = {
	generate = function(rng, _) return rng:bool(), nil end,
	shrink   = function(v, _)
		if not v then return EMPTY_ITER end
		local done = false
		return function()
			if done then return nil end; done = true
			return false, nil
		end
	end,
}

function M.constant(v)
	return {
		generate = function(_, _) return v, nil end,
		shrink   = function(_, _) return EMPTY_ITER end,
	}
end

-- ── String ────────────────────────────────────────────────────────────────────
-- ctx = nil.  Shrinks: binary-search length reduction, then per-char
-- simplification (toward lower byte values: 0, space, original-1).

function M.string(opts)
	opts = opts or {}
	local charset = opts.charset   -- nil = all bytes 1-127
	local min_len = opts.min or 0
	local max_len = opts.max       -- nil = size-derived

	return {
		generate = function(rng, sz)
			local top = max_len or math.min(sz, 20)
			local len = rng:int(min_len, math.max(min_len, top))
			local buf = {}
			if charset then
				local nc = #charset
				for i = 1, len do
					buf[i] = charset:sub(1 + (rng:next() % nc), 1 + (rng:next() % nc))
				end
			else
				for i = 1, len do buf[i] = string.char(rng:int(1, 127)) end
			end
			return table.concat(buf), nil
		end,

		shrink = function(v, _)
			if #v <= min_len then return EMPTY_ITER end
			-- Phase 1: binary-search length reduction.
			-- Phase 2: per-character simplification.
			local phase   = 1
			local len_diff = #v - min_len   -- amount we can still remove
			local char_idx = 1
			local char_sub = 0  -- candidate sub-phase within a character

			return function()
				-- Phase 1: length shrink
				if phase == 1 then
					while len_diff > 0 do
						local new_n = #v - len_diff
						len_diff    = math.floor(len_diff / 2)
						if new_n >= min_len then
							return v:sub(1, new_n), nil
						end
					end
					phase = 2
				end
				-- Phase 2: character simplification
				while char_idx <= #v do
					local b = string.byte(v, char_idx)
					-- Candidates: 0, 32 (space), b-1 — tried in char_sub order
					local candidates = {}
					if b > 0   then candidates[#candidates+1] = 0   end
					if b > 32  then candidates[#candidates+1] = 32  end
					if b > 1   then candidates[#candidates+1] = b-1 end
					char_sub = char_sub + 1
					if char_sub > #candidates then
						char_sub = 0
						char_idx = char_idx + 1
					else
						local nb = candidates[char_sub]
						local new_v = v:sub(1, char_idx-1)
							.. string.char(nb)
							.. v:sub(char_idx+1)
						if new_v ~= v then return new_v, nil end
					end
				end
				return nil
			end
		end,
	}
end

-- ── array shrink iterator ─────────────────────────────────────────────────────
-- Phase 1: binary-search length reduction (empty → half → three-quarters → ...).
-- Phase 2: per-element shrink using stored element contexts.

local function array_shrink_iter(vals, ctxs, elem_arb, min_len)
	local n = #vals
	if n <= min_len and n == 0 then return EMPTY_ITER end

	local phase    = n > min_len and 1 or 2
	local len_diff = n - min_len
	local eidx     = 1
	local eiter    = nil

	return function()
		-- Phase 1: length reduction
		if phase == 1 then
			while len_diff > 0 do
				local new_n = n - len_diff
				len_diff    = math.floor(len_diff / 2)
				if new_n >= min_len then
					local c = {}
					for i = 1, new_n do c[i] = vals[i] end
					return c, nil   -- ctx=nil: element ctxs lost, but length shrink is most impactful
				end
			end
			phase = 2
		end
		-- Phase 2: element shrink
		while eidx <= n do
			if not eiter then
				eiter = elem_arb.shrink(vals[eidx], ctxs and ctxs[eidx])
			end
			local sv, sc = eiter()
			if sv ~= nil then
				local c = {}; for i = 1, n do c[i] = vals[i] end; c[eidx] = sv
				local nc
				if ctxs or sc ~= nil then
					nc = {}
					for i = 1, n do nc[i] = ctxs and ctxs[i] end
					nc[eidx] = sc
				end
				return c, nc
			end
			eiter = nil; eidx = eidx + 1
		end
		return nil
	end
end

-- ── Collections ───────────────────────────────────────────────────────────────

function M.array(elem_arb, opts)
	opts = opts or {}
	local min_len = opts.min or 0
	local max_len = opts.max   -- nil = size-derived

	return {
		generate = function(rng, sz)
			local top  = max_len or sz
			local n    = rng:int(min_len, math.max(min_len, top))
			local vals = {}
			local ctxs = nil
			for i = 1, n do
				local v, c = elem_arb.generate(rng, sz)
				vals[i] = v
				if c ~= nil then
					if not ctxs then ctxs = {} end
					ctxs[i] = c
				end
			end
			return vals, ctxs   -- ctxs = nil when all element ctxs are nil
		end,
		shrink = function(v, c) return array_shrink_iter(v, c, elem_arb, min_len) end,
	}
end

-- Record: { field = arb, ... }  →  generates { field = val, ... }
-- ctx = nil when all field ctxs are nil, else { field = ctx, ... }
function M.record(spec)
	return {
		generate = function(rng, sz)
			local out  = {}
			local ctxs = nil
			for k, a in pairs(spec) do
				local v, c = a.generate(rng, sz)
				out[k] = v
				if c ~= nil then
					if not ctxs then ctxs = {} end
					ctxs[k] = c
				end
			end
			return out, ctxs
		end,
		shrink = function(vals, ctxs)
			-- Per-field shrink: try shrinking each field independently.
			local keys = {}; for k in pairs(spec) do keys[#keys+1] = k end
			local kidx = 1
			local kiter = nil
			return function()
				while kidx <= #keys do
					local k = keys[kidx]
					if not kiter then
						kiter = spec[k].shrink(vals[k], ctxs and ctxs[k])
					end
					local sv, sc = kiter()
					if sv ~= nil then
						local c = {}; for f, v in pairs(vals) do c[f] = v end; c[k] = sv
						local nc
						if ctxs or sc ~= nil then
							nc = {}
							for f, v in pairs(ctxs or {}) do nc[f] = v end
							nc[k] = sc
						end
						return c, nc
					end
					kiter = nil; kidx = kidx + 1
				end
				return nil
			end
		end,
	}
end

-- ── Combinators ───────────────────────────────────────────────────────────────

-- map: ctx = {pre_val, pre_ctx}.  Shrink delegates to inner arb, re-applies fn.
-- Allocates one {pre_val, pre_ctx} table per generated value (unavoidable).
function M.map(a, fn)
	return {
		generate = function(rng, sz)
			local v, c = a.generate(rng, sz)
			return fn(v), {v, c}
		end,
		shrink = function(_, ctx)
			if not ctx then return EMPTY_ITER end
			local pre_v, pre_c = ctx[1], ctx[2]
			local inner = a.shrink(pre_v, pre_c)
			return function()
				local sv, sc = inner()
				if sv == nil then return nil end
				return fn(sv), {sv, sc}
			end
		end,
	}
end

-- filter: ctx passes through unchanged.  Shrink skips invalid candidates.
function M.filter(a, pred, opts)
	local max_tries = opts and opts.max_tries or 100
	return {
		generate = function(rng, sz)
			for _ = 1, max_tries do
				local v, c = a.generate(rng, sz)
				if pred(v) then return v, c end
			end
			error("arb.filter: could not generate a satisfying value in "
				.. max_tries .. " attempts")
		end,
		shrink = function(v, c)
			local inner = a.shrink(v, c)
			return function()
				while true do
					local sv, sc = inner()
					if sv == nil then return nil end
					if pred(sv) then return sv, sc end
				end
			end
		end,
	}
end

-- one_of: ctx = {chosen_idx, inner_ctx}.  Allocates one table per trial.
-- NOTE: uses math.floor(rng:float() * n) for index selection rather than
-- rng:next() % n.  LCG low bits cycle with period 2 (LSBit alternates on
-- every call); when all arbs advance the RNG by the same number of calls the
-- index locks to one choice.  rng:float() uses the full 32-bit state range;
-- the MSBit has full-period distribution independent of the LSBit.
function M.one_of(arbs)
	assert(#arbs > 0, "arb.one_of: empty list")
	return {
		generate = function(rng, sz)
			local idx  = math.floor(rng:float() * #arbs) + 1
			local v, c = arbs[idx].generate(rng, sz)
			return v, {idx, c}
		end,
		shrink = function(v, ctx)
			if not ctx then return EMPTY_ITER end
			local idx, inner_c = ctx[1], ctx[2]
			local inner = arbs[idx].shrink(v, inner_c)
			return function()
				local sv, sc = inner()
				if sv == nil then return nil end
				return sv, {idx, sc}
			end
		end,
	}
end

-- tuple: ctx = ctxs table | nil (nil when all element ctxs are nil).
-- vals table is required anyway; ctxs allocated only when needed.
function M.tuple(arbs_list)
	assert(#arbs_list > 0, "arb.tuple: empty list")
	return {
		generate = function(rng, sz)
			local vals = {}
			local ctxs = nil
			for i, a in ipairs(arbs_list) do
				local v, c = a.generate(rng, sz)
				vals[i] = v
				if c ~= nil then
					if not ctxs then ctxs = {} end
					ctxs[i] = c
				end
			end
			return vals, ctxs
		end,
		shrink = function(vals, ctxs)
			local n    = #arbs_list
			local eidx = 1
			local eiter = nil
			return function()
				while eidx <= n do
					if not eiter then
						eiter = arbs_list[eidx].shrink(vals[eidx], ctxs and ctxs[eidx])
					end
					local sv, sc = eiter()
					if sv ~= nil then
						local c = {}; for i = 1, n do c[i] = vals[i] end; c[eidx] = sv
						local nc
						if ctxs or sc ~= nil then
							nc = {}
							for i = 1, n do nc[i] = ctxs and ctxs[i] end
							nc[eidx] = sc
						end
						return c, nc
					end
					eiter = nil; eidx = eidx + 1
				end
				return nil
			end
		end,
	}
end

-- sized: fn(size) -> arb.  ctx = {arb, inner_ctx}.  Allocates one table per trial.
function M.sized(fn)
	return {
		generate = function(rng, sz)
			local a    = fn(sz)
			local v, c = a.generate(rng, sz)
			return v, {a, c}
		end,
		shrink = function(v, ctx)
			if not ctx then return EMPTY_ITER end
			local a, inner_c = ctx[1], ctx[2]
			local inner = a.shrink(v, inner_c)
			return function()
				local sv, sc = inner()
				if sv == nil then return nil end
				return sv, {a, sc}
			end
		end,
	}
end

-- chain (monadic bind): fn(val) -> arb.
-- NOTE: only the second value is shrunk.  Shrinking the first value through
-- the dependency requires an RNG at shrink time, which we do not have.
-- If you need full chain shrinking, restructure as tuple + filter.
-- ctx = {v1, c1, b, c2} where b = fn(v1).
function M.chain(a, fn)
	return {
		generate = function(rng, sz)
			local v1, c1 = a.generate(rng, sz)
			local b      = fn(v1)
			local v2, c2 = b.generate(rng, sz)
			return v2, {v1, c1, b, c2}
		end,
		shrink = function(v2, ctx)
			-- Shrink second value only (see NOTE above).
			if not ctx then return EMPTY_ITER end
			local b, c2  = ctx[3], ctx[4]
			local v1, c1 = ctx[1], ctx[2]
			local inner  = b.shrink(v2, c2)
			return function()
				local sv, sc = inner()
				if sv == nil then return nil end
				return sv, {v1, c1, b, sc}
			end
		end,
	}
end

-- nil_or: nil (1-in-5) or a value from a.
function M.nil_or(a)
	return M.one_of({M.constant(nil), a})
end

-- frequency: {{weight, arb}, ...}
-- Uses rng:float() * total for selection (same LSBit reasoning as one_of).
function M.frequency(weighted)
	assert(#weighted > 0, "arb.frequency: empty list")
	local total = 0
	for _, w in ipairs(weighted) do total = total + w[1] end
	return {
		generate = function(rng, sz)
			local r   = rng:float() * total
			local cum = 0
			for idx, w in ipairs(weighted) do
				cum = cum + w[1]
				if r < cum then
					local v, c = w[2].generate(rng, sz)
					return v, {idx, c}
				end
			end
			local v, c = weighted[#weighted][2].generate(rng, sz)
			return v, {#weighted, c}
		end,
		shrink = function(v, ctx)
			if not ctx then return EMPTY_ITER end
			local idx, inner_c = ctx[1], ctx[2]
			local inner = weighted[idx][2].shrink(v, inner_c)
			return function()
				local sv, sc = inner()
				if sv == nil then return nil end
				return sv, {idx, sc}
			end
		end,
	}
end

-- ── Runner ────────────────────────────────────────────────────────────────────

local function display(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "string"  then return string.format("%q", v) end
	if t == "number"  then
		return v == math.floor(v) and math.abs(v) < 1e15
			and string.format("%d", v) or tostring(v)
	end
	if t == "boolean" then return tostring(v) end
	if t == "nil"     then return "nil" end
	if t ~= "table"   then return tostring(v) end
	if depth > 2      then return "{...}" end
	local parts, is_arr = {}, #v > 0
	if is_arr then
		for i = 1, math.min(#v, 8) do parts[#parts+1] = display(v[i], depth+1) end
		if #v > 8 then parts[#parts+1] = "...(" .. #v .. ")" end
	else
		local n = 0
		for k, val in pairs(v) do
			n = n + 1; if n > 6 then parts[#parts+1] = "..."; break end
			parts[#parts+1] = tostring(k) .. "=" .. display(val, depth+1)
		end
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function display_arg(v, is_tuple)
	if is_tuple then
		local parts = {}
		for i = 1, #v do parts[i] = display(v[i]) end
		return "(" .. table.concat(parts, ", ") .. ")"
	end
	return display(v)
end

-- Normalize arb_arg: single arb, or array of arbs → tuple.
-- Returns arb, is_tuple (bool).
local function normalize(arb_arg)
	if type(arb_arg) == "table" and arb_arg.generate then
		return arb_arg, false
	elseif type(arb_arg) == "table"
		and arb_arg[1] and type(arb_arg[1]) == "table" and arb_arg[1].generate
	then
		return M.tuple(arb_arg), true
	end
	error("arb.check: expected an arbitrary or array of arbitraries", 3)
end

local function make_runner(fn, is_tuple)
	if is_tuple then
		return function(v) return fn(unpack(v)) end
	else
		return function(v) return fn(v) end
	end
end

-- Shrink loop: find smallest failing val/ctx pair.
local function do_shrink(a, val, ctx, run, max_steps)
	local cur_v, cur_c = val, ctx
	local steps = 0
	while steps < max_steps do
		local iter  = a.shrink(cur_v, cur_c)
		local found = false
		while true do
			local sv, sc = iter()
			if sv == nil then break end
			if not pcall(run, sv) then
				cur_v, cur_c = sv, sc
				found = true
				steps = steps + 1
				break
			end
		end
		if not found then break end
	end
	return cur_v, steps
end

local DEFAULT_TRIALS    = 100
local DEFAULT_MAX_SHRINK = 500

local function get_seed()
	local s = os.getenv and os.getenv("PROP_SEED")
	if s then local n = tonumber(s); if n then return math.floor(n) end end
	return os.time()
end

-- arb.check: run N trials; shrink on failure.
-- Returns ok, info (nil on success).
-- info = { desc, trial, seed, original, shrunk, shrink_steps, err }
function M.check(desc, arb_arg, fn, opts)
	opts = opts or {}
	local trials    = opts.trials    or DEFAULT_TRIALS
	local seed      = opts.seed      or get_seed()
	local max_shrink = opts.max_shrink or DEFAULT_MAX_SHRINK

	local a, is_tuple = normalize(arb_arg)
	local run = make_runner(fn, is_tuple)
	local rng = gen_mod.make_rng(seed)

	for trial = 1, trials do
		local sz   = math.min(trial, 100)
		local v, c = a.generate(rng, sz)
		local ok, err = pcall(run, v)
		if not ok then
			local shrunk, steps = do_shrink(a, v, c, run, max_shrink)
			return false, {
				desc         = desc,
				trial        = trial,
				seed         = seed,
				original     = v,
				shrunk       = shrunk,
				shrink_steps = steps,
				err          = tostring(err),
				is_tuple     = is_tuple,
			}
		end
	end
	return true, nil
end

-- arb.it: register as a named test (integrates with lib/test/assert.lua).
function M.it(desc, arb_arg, fn, opts)
	local T = require("lib.test.assert")
	T.it(desc, function()
		local ok, info = M.check(desc, arb_arg, fn, opts)
		if not ok then
			local lines = {
				"property falsified after " .. info.trial
					.. " test" .. (info.trial == 1 and "" or "s")
					.. "  (seed=" .. info.seed
					.. ", replay: PROP_SEED=" .. info.seed .. ")",
				"  input:   " .. display_arg(info.original, info.is_tuple),
				"  shrunk:  " .. display_arg(info.shrunk, info.is_tuple)
					.. "  (" .. info.shrink_steps .. " step"
					.. (info.shrink_steps == 1 and "" or "s") .. ")",
				"  error:   " .. info.err,
			}
			error(table.concat(lines, "\n"), 2)
		end
	end)
end

-- arb.assert: inline property assertion (for use inside existing it() blocks).
function M.assert(desc, arb_arg, fn, opts)
	local ok, info = M.check(desc, arb_arg, fn, opts)
	if not ok then
		error(
			"property falsified after " .. info.trial .. " test(s)"
			.. "  (seed=" .. info.seed .. ")\n"
			.. "  input:  " .. display_arg(info.original, info.is_tuple) .. "\n"
			.. "  shrunk: " .. display_arg(info.shrunk, info.is_tuple) .. "\n"
			.. "  error:  " .. info.err,
			2
		)
	end
end

return M
