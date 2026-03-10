-- lib/test/gen.lua
-- Generators for property-based testing.
--
-- A generator is a table:
--   { generate(rng, size) -> value,  shrink(value) -> {smaller values} }
--
-- rng is a make_rng() handle; size is an integer hint for collection lengths.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local G = {}

-- === PRNG (LCG in double arithmetic — no bit.* dependency) ===

local LCG_MOD = 2^32
local LCG_A   = 1664525
local LCG_C   = 1013904223

function G.make_rng(seed)
	local state = math.floor(seed or os.time()) % LCG_MOD
	if state == 0 then state = 12345 end
	local rng  = { seed = seed or os.time() }
	function rng:next()
		state = (state * LCG_A + LCG_C) % LCG_MOD
		return state
	end
	function rng:float()                     -- [0, 1)
		return self:next() / LCG_MOD
	end
	function rng:int(lo, hi)                 -- [lo, hi] inclusive
		if lo >= hi then return lo end
		return lo + (self:next() % (hi - lo + 1))
	end
	function rng:bool() return self:next() % 2 == 0 end
	function rng:pick(t) return t[1 + (self:next() % #t)] end
	return rng
end

-- === Primitive generators ===

function G.constant(v)
	return {
		generate = function(_rng, _sz) return v end,
		shrink   = function(_v)        return {} end,
	}
end

G.bool = {
	generate = function(rng, _sz) return rng:bool() end,
	shrink   = function(v) return v and {false} or {} end,
}

-- Integer in [lo, hi].  Shrinks toward 0 (or lo when lo > 0).
function G.int(lo, hi)
	assert(lo <= hi, "gen.int: lo > hi")
	local target = math.max(lo, math.min(hi, 0))   -- closest to 0 in range
	return {
		generate = function(rng, _sz) return rng:int(lo, hi) end,
		shrink = function(v)
			if v == target then return {} end
			local candidates = {}
			-- Binary-search step toward target
			local mid = math.floor((v + target) / 2)
			if mid ~= v and mid >= lo and mid <= hi then
				candidates[#candidates+1] = mid
			end
			-- Single step toward target
			local step = v > target and v - 1 or v + 1
			if step ~= mid and step >= lo and step <= hi then
				candidates[#candidates+1] = step
			end
			return candidates
		end,
	}
end

G.uint = G.int(0, 2^31 - 1)
G.byte = G.int(0, 255)

-- Float in [lo, hi].  Shrinks by halving distance to 0.
function G.float(lo, hi)
	lo = lo or 0.0
	hi = hi or 1.0
	local target = math.max(lo, math.min(hi, 0.0))
	return {
		generate = function(rng, _sz) return lo + rng:float() * (hi - lo) end,
		shrink = function(v)
			if math.abs(v - target) < 1e-12 then return {} end
			return {(v + target) / 2}
		end,
	}
end

-- String from a charset.  opts: { charset=string, min=int, max=int }
-- Shrinks by removing characters (prefix, suffix, halve).
function G.string(opts)
	opts = opts or {}
	local charset = opts.charset or "abcdefghijklmnopqrstuvwxyz"
	local min_len = opts.min or 0
	local max_fn  = opts.max  -- nil → use size
	return {
		generate = function(rng, sz)
			local top  = max_fn or math.min(sz, 20)
			local len  = rng:int(min_len, math.max(min_len, top))
			local buf  = {}
			local nc   = #charset
			for i = 1, len do
				local ci = 1 + (rng:next() % nc)
				buf[i] = charset:sub(ci, ci)
			end
			return table.concat(buf)
		end,
		shrink = function(v)
			if #v <= min_len then return {} end
			local candidates = {}
			-- Remove last char
			if #v - 1 >= min_len then candidates[#candidates+1] = v:sub(1, #v - 1) end
			-- Remove first char
			if #v - 1 >= min_len and #v > 1 then candidates[#candidates+1] = v:sub(2) end
			-- Halve
			local half = math.floor(#v / 2)
			if half >= min_len and half < #v - 1 then
				candidates[#candidates+1] = v:sub(1, half)
			end
			return candidates
		end,
	}
end

-- List of elements.  opts: { min=int, max=int }
-- Shrinks by removing elements, then by shrinking individual elements.
function G.list(elem_gen, opts)
	opts = opts or {}
	local min_len = opts.min or 0
	local max_fn  = opts.max  -- nil → use size
	return {
		generate = function(rng, sz)
			local top = max_fn or sz
			local len = rng:int(min_len, math.max(min_len, top))
			local t   = {}
			for i = 1, len do t[i] = elem_gen.generate(rng, sz) end
			return t
		end,
		shrink = function(v)
			if #v <= min_len then return {} end
			local candidates = {}
			-- Drop each element
			for i = 1, #v do
				if #v - 1 >= min_len then
					local s = {}
					for j = 1, #v do if j ~= i then s[#s+1] = v[j] end end
					candidates[#candidates+1] = s
				end
			end
			-- Shrink each element (cap to avoid explosion)
			for i = 1, math.min(#v, 4) do
				for _, sv in ipairs(elem_gen.shrink(v[i])) do
					local c = {}
					for j = 1, #v do c[j] = v[j] end
					c[i] = sv
					candidates[#candidates+1] = c
				end
			end
			return candidates
		end,
	}
end

-- Table with generated keys and values.  opts: { min=int, max=int }
function G.table(k_gen, v_gen, opts)
	opts = opts or {}
	local min_n = opts.min or 0
	local max_n = opts.max or 5
	return {
		generate = function(rng, sz)
			local n   = rng:int(min_n, math.max(min_n, math.min(max_n, sz)))
			local out = {}
			for _ = 1, n do
				local k = k_gen.generate(rng, sz)
				local v = v_gen.generate(rng, sz)
				out[k] = v
			end
			return out
		end,
		shrink = function(v)
			local keys = {}
			for k in pairs(v) do keys[#keys+1] = k end
			if #keys == 0 then return {} end
			local candidates = {}
			for _, k in ipairs(keys) do
				local s = {}
				for ek, ev in pairs(v) do if ek ~= k then s[ek] = ev end end
				candidates[#candidates+1] = s
			end
			return candidates
		end,
	}
end

-- Pick uniformly from a list of generators.
function G.one_of(gens)
	assert(#gens > 0, "gen.one_of: empty list")
	return {
		generate = function(rng, sz)
			return gens[rng:int(1, #gens)].generate(rng, sz)
		end,
		shrink = function(v)
			local candidates = {}
			for _, g in ipairs(gens) do
				for _, s in ipairs(g.shrink(v)) do candidates[#candidates+1] = s end
			end
			return candidates
		end,
	}
end

-- Pick from generators with weights.  weighted = { {w, gen}, ... }
function G.frequency(weighted)
	assert(#weighted > 0, "gen.frequency: empty list")
	local total = 0
	for _, w in ipairs(weighted) do total = total + w[1] end
	return {
		generate = function(rng, sz)
			local r   = rng:next() % total
			local cum = 0
			for _, w in ipairs(weighted) do
				cum = cum + w[1]
				if r < cum then return w[2].generate(rng, sz) end
			end
			return weighted[#weighted][2].generate(rng, sz)
		end,
		shrink = function(v)
			local candidates = {}
			for _, w in ipairs(weighted) do
				for _, s in ipairs(w[2].shrink(v)) do candidates[#candidates+1] = s end
			end
			return candidates
		end,
	}
end

-- Generator that depends on the size parameter.  fn(size) -> gen
function G.sized(fn)
	return {
		generate = function(rng, sz) return fn(sz).generate(rng, sz) end,
		-- Use a small fixed size for shrinking (we don't know the original size)
		shrink   = function(v) return fn(10).shrink(v) end,
	}
end

-- Transform generated values.
-- Note: shrinking goes back through the original generator, not the mapping,
-- so shrunk candidates are re-mapped.
function G.map(g, fn)
	return {
		generate = function(rng, sz) return fn(g.generate(rng, sz)) end,
		-- Shrink the pre-image by delegating to g, then re-map
		shrink = function(v)
			-- Without the pre-image we cannot shrink; callers who need shrinking
			-- should annotate using gen.map2 or build a dedicated generator.
			return {}
		end,
	}
end

-- Filter generated values to satisfy a predicate.
function G.filter(g, pred)
	return {
		generate = function(rng, sz)
			for _ = 1, 100 do
				local v = g.generate(rng, sz)
				if pred(v) then return v end
			end
			error("gen.filter: could not generate a satisfying value in 100 attempts")
		end,
		shrink = function(v)
			local candidates = {}
			for _, s in ipairs(g.shrink(v)) do
				if pred(s) then candidates[#candidates+1] = s end
			end
			return candidates
		end,
	}
end

-- Either nil (1-in-5 chance) or a value from g.
function G.nil_or(g)
	return G.frequency({{1, G.constant(nil)}, {4, g}})
end

-- Tuple: generate/shrink multiple values together.
-- gens is an array of generators; produce an array of values.
function G.tuple(gens)
	assert(#gens > 0, "gen.tuple: empty list")
	return {
		generate = function(rng, sz)
			local out = {}
			for i, g in ipairs(gens) do out[i] = g.generate(rng, sz) end
			return out
		end,
		shrink = function(v)
			local candidates = {}
			for i, g in ipairs(gens) do
				for _, sv in ipairs(g.shrink(v[i])) do
					local c = {}
					for j, x in ipairs(v) do c[j] = x end
					c[i] = sv
					candidates[#candidates+1] = c
				end
			end
			return candidates
		end,
	}
end

return G
