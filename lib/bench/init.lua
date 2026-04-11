-- lib/bench/init.lua
-- Micro-benchmarking framework with statistics.
--
-- Usage:
--   local bench = require("lib.bench")
--   local result = bench.run(fn, {duration=1.0, warmup=0.1, min_iters=100})
--   print(result:format())
--
--   local suite = bench.suite("My suite")
--   suite:add("case1", fn1)
--   suite:add("case2", fn2)
--   suite:print(suite:run({duration=0.5}))

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Clock: injectable; default is os.clock() * 1e9 (CPU nanoseconds).
-- Try luasocket for wall-clock if available; fall back to os.clock.
-- ---------------------------------------------------------------------------

local _default_clock
do
  local ok, socket = pcall(require, "socket")
  if ok and socket.gettime then
    _default_clock = function() return socket.gettime() * 1e9 end
  else
    _default_clock = function() return os.clock() * 1e9 end
  end
end

-- ---------------------------------------------------------------------------
-- Statistics helpers
-- ---------------------------------------------------------------------------

-- Compute statistics over a numeric array of samples.
-- Returns {mean, median, min, max, stddev, p95, p99}.
--:: Stats = { mean: number, median: number, min: number, max: number, stddev: number, p95: number, p99: number }
function M.stats(samples)
  local n = #samples
  if n == 0 then
    return { mean=0, median=0, min=0, max=0, stddev=0, p95=0, p99=0 }
  end

  -- sort a copy
  local s = {}
  for i = 1, n do s[i] = samples[i] end
  table.sort(s)

  local sum = 0
  for i = 1, n do sum = sum + s[i] end
  local mean = sum / n

  local var_sum = 0
  for i = 1, n do
    local d = s[i] - mean
    var_sum = var_sum + d * d
  end
  local stddev = n > 1 and math.sqrt(var_sum / (n - 1)) or 0

  local function percentile(arr, pct)
    local idx = math.max(1, math.ceil(pct * #arr))
    return arr[idx]
  end

  local median
  if n % 2 == 1 then
    median = s[math.ceil(n / 2)]
  else
    median = (s[n / 2] + s[n / 2 + 1]) / 2
  end

  return {
    mean   = mean,
    median = median,
    min    = s[1],
    max    = s[n],
    stddev = stddev,
    p95    = percentile(s, 0.95),
    p99    = percentile(s, 0.99),
  }
end

-- Format a nanosecond value as a human-readable string.
-- < 1000 ns  → "Xns"
-- < 1e6 ns   → "X.XXµs"
-- < 1e9 ns   → "X.XXms"
-- else       → "X.XXs"
function M.format_ns(ns)
  if ns < 1000 then
    return string.format("%.2fns", ns)
  elseif ns < 1e6 then
    return string.format("%.2f\xc2\xb5s", ns / 1e3)
  elseif ns < 1e9 then
    return string.format("%.2fms", ns / 1e6)
  else
    return string.format("%.2fs", ns / 1e9)
  end
end

-- Format an ops/sec value as a human-readable string.
-- >= 1e9  → "X.XXG ops/sec"
-- >= 1e6  → "X.XXM ops/sec"
-- >= 1e3  → "X.XXk ops/sec"
-- else    → "X ops/sec"
function M.format_ops(ops)
  if ops >= 1e9 then
    return string.format("%.2fG ops/sec", ops / 1e9)
  elseif ops >= 1e6 then
    return string.format("%.2fM ops/sec", ops / 1e6)
  elseif ops >= 1e3 then
    return string.format("%.2fk ops/sec", ops / 1e3)
  else
    return string.format("%.0f ops/sec", ops)
  end
end

-- ---------------------------------------------------------------------------
-- Result metatable
-- ---------------------------------------------------------------------------

local ResultMT = {}
ResultMT.__index = ResultMT

function ResultMT:format()
  return string.format(
    "mean=%s \xc2\xb1%s, %s, %d iters",
    M.format_ns(self.mean_ns),
    M.format_ns(self.stddev_ns),
    M.format_ops(self.ops_per_sec),
    self.iters
  )
end

ResultMT.__tostring = ResultMT.format

-- Build a Result from raw sample data.
-- samples: array of per-iteration nanoseconds
-- total_ns: total nanoseconds of the measurement phase
local function make_result(samples, total_ns, overhead_ns)
  overhead_ns = overhead_ns or 0
  local n = #samples
  -- subtract calibration overhead from each sample (clamp to 0)
  if overhead_ns > 0 then
    for i = 1, n do
      samples[i] = math.max(0, samples[i] - overhead_ns)
    end
  end

  local st = M.stats(samples)
  local total_sec = total_ns / 1e9
  local ops_per_sec = total_sec > 0 and (n / total_sec) or 0

  local r = {
    iters       = n,
    total_ns    = total_ns,
    mean_ns     = st.mean,
    median_ns   = st.median,
    min_ns      = st.min,
    max_ns      = st.max,
    stddev_ns   = st.stddev,
    p95_ns      = st.p95,
    p99_ns      = st.p99,
    ops_per_sec = ops_per_sec,
  }
  return setmetatable(r, ResultMT)
end

-- ---------------------------------------------------------------------------
-- Calibration
-- ---------------------------------------------------------------------------

-- Measure the overhead of the benchmarking loop itself (ns/iter).
-- Runs an empty function through the measurement path and returns mean_ns.
function M.calibrate(opts)
  opts = opts or {}
  local clock = opts.clock or _default_clock
  local iters = opts.iters or 1000

  local samples = {}
  for i = 1, iters do
    local t0 = clock()
    local t1 = clock()
    samples[i] = t1 - t0
  end

  local st = M.stats(samples)
  return st.mean
end

-- ---------------------------------------------------------------------------
-- bench.run
-- ---------------------------------------------------------------------------

-- Run fn for the specified duration and return a Result.
-- opts:
--   duration   (number, default 1.0) seconds to run
--   warmup     (number, default 0.1) seconds for warmup
--   min_iters  (number, default 100) minimum iterations
--   clock      (function) injectable clock returning nanoseconds
--   overhead_ns (number) calibration overhead to subtract (default 0)
--   batch      (number) iterations per timing sample (auto-detected if nil)
function M.run(fn, opts)
  opts = opts or {}
  local duration    = opts.duration  or 1.0
  local warmup      = opts.warmup    or 0.1
  local min_iters   = opts.min_iters or 100
  local clock       = opts.clock     or _default_clock
  local overhead_ns = opts.overhead_ns or 0

  -- warmup phase
  local warmup_ns = warmup * 1e9
  local w0 = clock()
  while clock() - w0 < warmup_ns do
    fn()
  end

  -- auto-detect batch size: time a single call; if < 100ns, batch enough to
  -- get a reading > 1µs per batch (to avoid clock resolution noise).
  local batch = opts.batch
  if not batch then
    local s0 = clock()
    fn()
    local single = clock() - s0
    if single < 100 then
      -- aim for ~10µs per batch sample
      batch = math.max(1, math.floor(10000 / math.max(1, single)))
    else
      batch = 1
    end
  end

  -- measurement phase
  local samples = {}
  local total_start = clock()
  local budget_ns = duration * 1e9
  local iters_done = 0

  while true do
    -- run one batch
    local t0 = clock()
    for _ = 1, batch do
      fn()
    end
    local t1 = clock()
    local per_iter = (t1 - t0) / batch
    for _ = 1, batch do
      samples[#samples + 1] = per_iter
    end
    iters_done = iters_done + batch

    -- check stopping conditions
    local elapsed = clock() - total_start
    if elapsed >= budget_ns and iters_done >= min_iters then
      break
    end
  end

  local total_ns = clock() - total_start

  return make_result(samples, total_ns, overhead_ns)
end

-- ---------------------------------------------------------------------------
-- Throughput variant
-- ---------------------------------------------------------------------------

-- Like bench.run but reports bytes/sec and MB/s in addition.
-- fn(size) is called with size_bytes; result has .bytes_per_sec and .mb_per_sec.
-- result:format() returns "X.XX GB/s" style string.
function M.throughput(fn, size_bytes, opts)
  opts = opts or {}
  local bound_fn = function() fn(size_bytes) end
  local result = M.run(bound_fn, opts)

  result.size_bytes    = size_bytes
  result.bytes_per_sec = result.ops_per_sec * size_bytes
  result.mb_per_sec    = result.bytes_per_sec / (1024 * 1024)

  -- override format for throughput results
  local orig_mt = getmetatable(result)
  local ThroughputMT = {}
  ThroughputMT.__index = ThroughputMT
  setmetatable(ThroughputMT, { __index = orig_mt })

  function ThroughputMT:format()
    local bps = self.bytes_per_sec
    if bps >= 1e9 then
      return string.format("%.2f GB/s", bps / 1e9)
    elseif bps >= 1e6 then
      return string.format("%.2f MB/s", bps / 1e6)
    elseif bps >= 1e3 then
      return string.format("%.2f KB/s", bps / 1e3)
    else
      return string.format("%.0f B/s", bps)
    end
  end
  ThroughputMT.__tostring = ThroughputMT.format

  return setmetatable(result, ThroughputMT)
end

-- ---------------------------------------------------------------------------
-- Suite
-- ---------------------------------------------------------------------------

local SuiteMT = {}
SuiteMT.__index = SuiteMT

-- Add a named benchmark to the suite.
function SuiteMT:add(name, fn)
  self._cases[#self._cases + 1] = { name = name, fn = fn }
end

-- Run all benchmarks; return array of {name, result}.
function SuiteMT:run(opts)
  local results = {}
  for i = 1, #self._cases do
    local c = self._cases[i]
    results[i] = { name = c.name, result = M.run(c.fn, opts) }
  end
  return results
end

-- Pretty-print a comparison table sorted by mean (fastest first).
-- Shows relative speedup vs the slowest entry.
function SuiteMT:print(results)
  -- find slowest mean
  local slowest = 0
  for _, r in ipairs(results) do
    if r.result.mean_ns > slowest then slowest = r.result.mean_ns end
  end

  -- sort by mean ascending (copy)
  local sorted = {}
  for i, r in ipairs(results) do sorted[i] = r end
  table.sort(sorted, function(a, b) return a.result.mean_ns < b.result.mean_ns end)

  -- determine column widths
  local name_w = 4  -- "name"
  for _, r in ipairs(sorted) do
    if #r.name > name_w then name_w = #r.name end
  end

  -- header
  local title = self._name and ("Benchmark suite: " .. self._name) or "Benchmark suite"
  io.write(title .. "\n")
  io.write(string.format("%-" .. name_w .. "s  %12s  %12s  %12s  %10s  %8s\n",
    "name", "mean", "±stddev", "min", "ops/sec", "speedup"))
  io.write(string.rep("-", name_w + 2 + 12 + 2 + 12 + 2 + 12 + 2 + 10 + 2 + 8) .. "\n")

  for _, r in ipairs(sorted) do
    local res = r.result
    local speedup = slowest > 0 and (slowest / res.mean_ns) or 1
    io.write(string.format("%-" .. name_w .. "s  %12s  %12s  %12s  %10s  %7.2fx\n",
      r.name,
      M.format_ns(res.mean_ns),
      M.format_ns(res.stddev_ns),
      M.format_ns(res.min_ns),
      M.format_ops(res.ops_per_sec),
      speedup))
  end
end

-- Create a named benchmark suite.
function M.suite(name)
  return setmetatable({ _name = name, _cases = {} }, SuiteMT)
end

return M
