-- lib/iter/bench.lua
-- Benchmark iter combinator overhead vs hand-written loops over 1M elements.
-- Run: luajit lib/iter/bench.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local iter = require("lib.iter")

local N       = 1000000
local WARMUP  = 3
local REPS    = 10

-- Pre-build the source array once (array allocation is not what we measure).
local src = {}
for i = 1, N do src[i] = i end

----------------------------------------------------------------
-- Benchmark harness
----------------------------------------------------------------

local function bench(fn)
  for _ = 1, WARMUP do fn() end
  local t0 = os.clock()
  for _ = 1, REPS do fn() end
  local t1 = os.clock()
  return (t1 - t0) / REPS  -- seconds per run
end

-- Prevent the compiler from eliminating results entirely.
local _sink = 0
local function sink(v) _sink = _sink + (v or 0) end

----------------------------------------------------------------
-- Benchmarks
----------------------------------------------------------------

-- Closures hoisted to module level so each case reuses the same closure
-- object. LuaJIT's fold loop compiles a trace guarded on a specific closure
-- identity; if a second distinct closure object runs the same fold loop, the
-- guard fails and JIT falls back to interpreter. Sharing one object across all
-- cases that perform the same operation avoids this.
local fn_double   = function(v) return v * 2 end
local fn_odd      = function(v) return v % 2 == 1 end
local fn_gt_N     = function(v) return v > N end
local fn_add      = function(a, v) return a + v end

local cases = {}

-- map: multiply each element by 2, sum result
cases[#cases+1] = {
  name = "map (loop)",
  fn = function()
    local s = 0
    for i = 1, N do s = s + src[i] * 2 end
    sink(s)
  end,
}
cases[#cases+1] = {
  name = "map (iter)",
  fn = function()
    sink(iter.sum(iter.map(fn_double, iter.values(src))))
  end,
}

-- filter: keep odd elements, sum result
cases[#cases+1] = {
  name = "filter (loop)",
  fn = function()
    local s = 0
    for i = 1, N do
      local v = src[i]
      if v % 2 == 1 then s = s + v end
    end
    sink(s)
  end,
}
cases[#cases+1] = {
  name = "filter (iter)",
  fn = function()
    sink(iter.sum(iter.filter(fn_odd, iter.values(src))))
  end,
}

-- reduce: sum all elements via fold
cases[#cases+1] = {
  name = "fold (loop)",
  fn = function()
    local s = 0
    for i = 1, N do s = s + src[i] end
    sink(s)
  end,
}
cases[#cases+1] = {
  name = "fold (iter)",
  fn = function()
    sink(iter.fold(fn_add, 0, iter.values(src)))
  end,
}

-- map+filter chain: double then keep >1M, sum
cases[#cases+1] = {
  name = "map+filter (loop)",
  fn = function()
    local s = 0
    for i = 1, N do
      local v = src[i] * 2
      if v > N then s = s + v end
    end
    sink(s)
  end,
}
cases[#cases+1] = {
  name = "map+filter (iter)",
  fn = function()
    sink(iter.sum(iter.filter(fn_gt_N, iter.map(fn_double, iter.values(src)))))
  end,
}

-- map+filter+fold chain
cases[#cases+1] = {
  name = "map+filt+fold (loop)",
  fn = function()
    local s = 0
    for i = 1, N do
      local v = src[i] * 2
      if v > N then s = s + v end
    end
    sink(s)
  end,
}
cases[#cases+1] = {
  name = "map+filt+fold (iter)",
  fn = function()
    sink(iter.fold(fn_add, 0, iter.filter(fn_gt_N, iter.map(fn_double, iter.values(src)))))
  end,
}

----------------------------------------------------------------
-- Run and report
----------------------------------------------------------------

io.write(string.format(
  "iter combinator benchmark — %dM elements, %d reps (after %d warmup)\n\n",
  N / 1000000, REPS, WARMUP))

io.write(string.format("%-24s  %10s  %12s\n",
  "case", "total (ms)", "ns/element"))
io.write(string.rep("-", 52) .. "\n")

local results = {}
for _, c in ipairs(cases) do
  local secs = bench(c.fn)
  local ms   = secs * 1000
  local nspe = secs * 1e9 / N
  results[#results+1] = { name = c.name, ms = ms, nspe = nspe }
  io.write(string.format("%-24s  %10.2f  %12.1f\n", c.name, ms, nspe))
end

-- Print overhead ratios for each (iter / loop) pair
io.write("\n")
io.write(string.format("%-24s  %s\n", "overhead (iter/loop)", "ratio"))
io.write(string.rep("-", 38) .. "\n")
local i = 1
while i < #results do
  local loop_r = results[i]
  local iter_r = results[i+1]
  local ratio  = iter_r.ms / loop_r.ms
  io.write(string.format("%-24s  %.2fx\n", iter_r.name, ratio))
  i = i + 2
end

io.write(string.format("\n(sink=%d — prevents dead-code elimination)\n", _sink))
