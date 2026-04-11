-- lib/bench/bench_test.lua
-- Tests for the lib/bench micro-benchmarking library.
--
-- Strategy: avoid relying on real timing values (non-deterministic).
-- Use a fake injectable clock for bench.run tests.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local bench = require("lib.bench")

-- ---------------------------------------------------------------------------
-- bench.stats
-- ---------------------------------------------------------------------------

T.describe("bench.stats", function()

  T.it("empty input returns zeros", function()
    local s = bench.stats({})
    T.eq(s.mean,   0)
    T.eq(s.median, 0)
    T.eq(s.min,    0)
    T.eq(s.max,    0)
    T.eq(s.stddev, 0)
    T.eq(s.p95,    0)
    T.eq(s.p99,    0)
  end)

  T.it("single element", function()
    local s = bench.stats({42})
    T.eq(s.mean,   42)
    T.eq(s.median, 42)
    T.eq(s.min,    42)
    T.eq(s.max,    42)
    T.eq(s.stddev, 0)
    T.eq(s.p95,    42)
    T.eq(s.p99,    42)
  end)

  T.it("five elements: mean, min, max", function()
    local s = bench.stats({1, 2, 3, 4, 5})
    T.eq(s.mean, 3)
    T.eq(s.min,  1)
    T.eq(s.max,  5)
  end)

  T.it("five elements: median (odd count)", function()
    local s = bench.stats({5, 1, 3, 2, 4})  -- unsorted input
    T.eq(s.median, 3)
  end)

  T.it("four elements: median (even count)", function()
    local s = bench.stats({1, 2, 3, 4})
    T.eq(s.median, 2.5)
  end)

  T.it("stddev of identical values is 0", function()
    local s = bench.stats({7, 7, 7, 7})
    T.eq(s.stddev, 0)
  end)

  T.it("stddev of {2,4,4,4,5,5,7,9} ≈ 2.0", function()
    -- classic textbook example: population stddev = 2, sample stddev ≈ 2.138
    local s = bench.stats({2, 4, 4, 4, 5, 5, 7, 9})
    T.ok(s.stddev > 1.9 and s.stddev < 2.5, "stddev in expected range")
  end)

  T.it("p95 is at/near 95th percentile", function()
    local data = {}
    for i = 1, 100 do data[i] = i end
    local s = bench.stats(data)
    -- 95th percentile of 1..100 is 95
    T.eq(s.p95, 95)
  end)

  T.it("p99 is at/near 99th percentile", function()
    local data = {}
    for i = 1, 100 do data[i] = i end
    local s = bench.stats(data)
    T.eq(s.p99, 99)
  end)

  T.it("does not mutate input array", function()
    local data = {3, 1, 2}
    bench.stats(data)
    T.eq(data[1], 3)
    T.eq(data[2], 1)
    T.eq(data[3], 2)
  end)

end)

-- ---------------------------------------------------------------------------
-- bench.format_ns
-- ---------------------------------------------------------------------------

T.describe("bench.format_ns", function()

  T.it("formats < 1000 as ns", function()
    local s = bench.format_ns(1)
    T.ok(s:find("ns"), "contains 'ns': " .. s)
  end)

  T.it("formats 999 as ns", function()
    local s = bench.format_ns(999)
    T.ok(s:find("ns"), "contains 'ns': " .. s)
  end)

  T.it("formats 1000 as µs", function()
    local s = bench.format_ns(1000)
    -- µ is 0xc2 0xb5 in UTF-8; just check 's' after it or 'us'
    T.ok(s:find("\xc2\xb5s") or s:find("us"), "contains µs: " .. s)
  end)

  T.it("formats 1500 as 1.50µs", function()
    local s = bench.format_ns(1500)
    T.ok(s:find("1.50"), "contains 1.50: " .. s)
  end)

  T.it("formats 999999 as µs range", function()
    local s = bench.format_ns(999999)
    T.ok(s:find("\xc2\xb5s") or s:find("us"), "contains µs: " .. s)
  end)

  T.it("formats 1e6 as ms", function()
    local s = bench.format_ns(1e6)
    T.ok(s:find("ms"), "contains 'ms': " .. s)
  end)

  T.it("formats 1.5e6 as 1.50ms", function()
    local s = bench.format_ns(1.5e6)
    T.ok(s:find("1.50"), "contains 1.50: " .. s)
    T.ok(s:find("ms"), "contains 'ms': " .. s)
  end)

  T.it("formats 1e9 as s", function()
    local s = bench.format_ns(1e9)
    T.ok(s:find("s") and not s:find("ms") and not s:find("ns"), "contains 's' only: " .. s)
  end)

  T.it("formats 2.5e9 as 2.50s", function()
    local s = bench.format_ns(2.5e9)
    T.ok(s:find("2.50"), "contains 2.50: " .. s)
    T.ok(s:find("s"), "contains 's': " .. s)
  end)

end)

-- ---------------------------------------------------------------------------
-- bench.format_ops
-- ---------------------------------------------------------------------------

T.describe("bench.format_ops", function()

  T.it("formats < 1000 as plain ops/sec", function()
    local s = bench.format_ops(500)
    T.ok(s:find("ops/sec"), "contains 'ops/sec': " .. s)
    T.ok(not s:find("k") and not s:find("M") and not s:find("G"), "no prefix: " .. s)
  end)

  T.it("formats 1000 as k ops/sec", function()
    local s = bench.format_ops(1000)
    T.ok(s:find("k ops/sec"), "contains 'k ops/sec': " .. s)
  end)

  T.it("formats 1500 as 1.50k ops/sec", function()
    local s = bench.format_ops(1500)
    T.ok(s:find("1.50k"), "contains '1.50k': " .. s)
  end)

  T.it("formats 1e6 as M ops/sec", function()
    local s = bench.format_ops(1e6)
    T.ok(s:find("M ops/sec"), "contains 'M ops/sec': " .. s)
  end)

  T.it("formats 1.23e6 as 1.23M ops/sec", function()
    local s = bench.format_ops(1.23e6)
    T.ok(s:find("1.23M"), "contains '1.23M': " .. s)
  end)

  T.it("formats 1e9 as G ops/sec", function()
    local s = bench.format_ops(1e9)
    T.ok(s:find("G ops/sec"), "contains 'G ops/sec': " .. s)
  end)

  T.it("formats 2.5e9 as 2.50G ops/sec", function()
    local s = bench.format_ops(2.5e9)
    T.ok(s:find("2.50G"), "contains '2.50G': " .. s)
  end)

end)

-- ---------------------------------------------------------------------------
-- bench.run with injectable clock
-- ---------------------------------------------------------------------------

-- Fake clock: each call advances by `step_ns` nanoseconds.
-- Useful for deterministic tests.
local function make_clock(step_ns)
  local t = 0
  return function()
    t = t + step_ns
    return t
  end
end

T.describe("bench.run", function()

  T.it("returns a result with all expected fields", function()
    local counter = 0
    local result = bench.run(function() counter = counter + 1 end, {
      duration  = 0.01,
      warmup    = 0.0,
      min_iters = 10,
      clock     = make_clock(1000),  -- 1µs per call
    })
    T.ok(result.iters     ~= nil, "iters present")
    T.ok(result.total_ns  ~= nil, "total_ns present")
    T.ok(result.mean_ns   ~= nil, "mean_ns present")
    T.ok(result.median_ns ~= nil, "median_ns present")
    T.ok(result.min_ns    ~= nil, "min_ns present")
    T.ok(result.max_ns    ~= nil, "max_ns present")
    T.ok(result.stddev_ns ~= nil, "stddev_ns present")
    T.ok(result.ops_per_sec ~= nil, "ops_per_sec present")
  end)

  T.it("iters >= min_iters", function()
    local result = bench.run(function() end, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 50,
      clock     = make_clock(100),
    })
    T.ok(result.iters >= 50, "iters >= 50, got " .. tostring(result.iters))
  end)

  T.it("counter incremented once per iter", function()
    local count = 0
    local result = bench.run(function() count = count + 1 end, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 20,
      clock     = make_clock(100),
      batch     = 1,
    })
    -- warmup is 0 so all calls are in measurement; count should equal iters
    T.ok(count >= result.iters, "count >= iters: count=" .. count .. " iters=" .. result.iters)
  end)

  T.it(":format() returns a non-empty string", function()
    local result = bench.run(function() end, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(500),
    })
    local s = result:format()
    T.ok(type(s) == "string" and #s > 0, "format() returns non-empty string")
  end)

  T.it("tostring(result) equals result:format()", function()
    local result = bench.run(function() end, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(500),
    })
    T.eq(tostring(result), result:format())
  end)

  T.it("format() string contains 'iters'", function()
    local result = bench.run(function() end, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 7,
      clock     = make_clock(1000),
    })
    local s = result:format()
    T.ok(s:find("iters"), "format contains 'iters': " .. s)
  end)

  T.it("format() string contains 'mean='", function()
    local result = bench.run(function() end, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(1000),
    })
    local s = result:format()
    T.ok(s:find("mean="), "format contains 'mean=': " .. s)
  end)

  T.it("format() string contains 'ops/sec'", function()
    local result = bench.run(function() end, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(1000),
    })
    local s = result:format()
    T.ok(s:find("ops/sec"), "format contains 'ops/sec': " .. s)
  end)

  T.it("ops_per_sec > 0 when total_ns > 0", function()
    local result = bench.run(function() end, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(1000),
    })
    T.ok(result.ops_per_sec > 0, "ops_per_sec > 0")
  end)

  T.it("min_ns <= mean_ns <= max_ns", function()
    local result = bench.run(function() end, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 20,
      clock     = make_clock(500),
    })
    T.ok(result.min_ns <= result.mean_ns, "min <= mean")
    T.ok(result.mean_ns <= result.max_ns, "mean <= max")
  end)

  T.it("overhead_ns is subtracted from samples", function()
    -- clock step 2000ns; overhead 1000ns; net should be ~1000ns per iter
    local result = bench.run(function() end, {
      duration     = 0.0,
      warmup       = 0.0,
      min_iters    = 10,
      clock        = make_clock(2000),
      overhead_ns  = 1000,
      batch        = 1,
    })
    T.ok(result.mean_ns >= 0, "mean_ns >= 0 after overhead subtraction")
  end)

end)

-- ---------------------------------------------------------------------------
-- bench.calibrate
-- ---------------------------------------------------------------------------

T.describe("bench.calibrate", function()

  T.it("returns a number", function()
    local overhead = bench.calibrate({ iters = 50, clock = make_clock(10) })
    T.ok(type(overhead) == "number", "calibrate returns number")
  end)

  T.it("returns non-negative value", function()
    local overhead = bench.calibrate({ iters = 100, clock = make_clock(10) })
    T.ok(overhead >= 0, "overhead >= 0, got " .. tostring(overhead))
  end)

  T.it("overhead with 10ns clock steps is ~10ns", function()
    -- each calibration iteration calls clock twice: t0 and t1
    -- step=10 means t1-t0 = 10
    local overhead = bench.calibrate({ iters = 100, clock = make_clock(10) })
    T.ok(overhead >= 5 and overhead <= 30, "overhead near 10ns: " .. tostring(overhead))
  end)

end)

-- ---------------------------------------------------------------------------
-- bench.suite
-- ---------------------------------------------------------------------------

T.describe("bench.suite", function()

  T.it("suite:run returns array with correct names", function()
    local s = bench.suite("Test suite")
    s:add("alpha", function() end)
    s:add("beta",  function() end)
    s:add("gamma", function() end)
    local results = s:run({
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(1000),
    })
    T.eq(#results, 3)
    T.eq(results[1].name, "alpha")
    T.eq(results[2].name, "beta")
    T.eq(results[3].name, "gamma")
  end)

  T.it("each suite result has a result field", function()
    local s = bench.suite("Test suite 2")
    s:add("x", function() end)
    local results = s:run({
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(1000),
    })
    T.ok(results[1].result ~= nil, "result field present")
    T.ok(results[1].result.iters ~= nil, "result.iters present")
  end)

  T.it("empty suite returns empty array", function()
    local s = bench.suite("Empty")
    local results = s:run({ duration=0.0, warmup=0.0, min_iters=1, clock=make_clock(100) })
    T.eq(#results, 0)
  end)

  T.it("suite:run respects opts.min_iters for each case", function()
    local s = bench.suite("iters check")
    s:add("a", function() end)
    s:add("b", function() end)
    local results = s:run({
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 30,
      clock     = make_clock(100),
    })
    T.ok(results[1].result.iters >= 30, "case a iters >= 30")
    T.ok(results[2].result.iters >= 30, "case b iters >= 30")
  end)

  T.it("suite:print outputs something (smoke test)", function()
    -- capture output by temporarily redirecting io.write
    local captured = {}
    local orig = io.write
    io.write = function(s) captured[#captured+1] = s end

    local s = bench.suite("Smoke suite")
    s:add("fast", function() end)
    s:add("slow", function() end)
    local results = s:run({
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(500),
    })
    s:print(results)

    io.write = orig  -- restore

    local all = table.concat(captured, "")
    T.ok(#all > 0, "print produced output")
    T.ok(all:find("fast"), "output contains 'fast'")
    T.ok(all:find("slow"), "output contains 'slow'")
  end)

end)

-- ---------------------------------------------------------------------------
-- bench.throughput
-- ---------------------------------------------------------------------------

T.describe("bench.throughput", function()

  T.it("result has bytes_per_sec and mb_per_sec", function()
    local result = bench.throughput(function(_size) end, 1024, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(1000),
    })
    T.ok(result.bytes_per_sec ~= nil, "bytes_per_sec present")
    T.ok(result.mb_per_sec    ~= nil, "mb_per_sec present")
  end)

  T.it("bytes_per_sec = ops_per_sec * size_bytes", function()
    local result = bench.throughput(function(_size) end, 512, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 10,
      clock     = make_clock(1000),
    })
    local expected = result.ops_per_sec * 512
    -- allow small floating-point drift
    local diff = math.abs(result.bytes_per_sec - expected)
    T.ok(diff < 1, "bytes_per_sec ≈ ops*size: diff=" .. tostring(diff))
  end)

  T.it("format() returns a throughput string (B/s / KB/s / MB/s / GB/s)", function()
    local result = bench.throughput(function(_size) end, 1024, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(1000),
    })
    local s = result:format()
    T.ok(
      s:find("B/s") or s:find("KB/s") or s:find("MB/s") or s:find("GB/s"),
      "throughput format contains bandwidth unit: " .. s
    )
  end)

  T.it("size_bytes is stored on result", function()
    local result = bench.throughput(function(_size) end, 4096, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(1000),
    })
    T.eq(result.size_bytes, 4096)
  end)

  T.it("mb_per_sec = bytes_per_sec / (1024*1024)", function()
    local result = bench.throughput(function(_size) end, 2048, {
      duration  = 0.0,
      warmup    = 0.0,
      min_iters = 5,
      clock     = make_clock(1000),
    })
    local expected_mb = result.bytes_per_sec / (1024 * 1024)
    local diff = math.abs(result.mb_per_sec - expected_mb)
    T.ok(diff < 0.001, "mb_per_sec correct: diff=" .. tostring(diff))
  end)

end)

-- ---------------------------------------------------------------------------
-- Real clock smoke tests (very short)
-- ---------------------------------------------------------------------------

T.describe("bench.run (real clock)", function()

  T.it("runs without error using real clock", function()
    local result = bench.run(function()
      -- tiny work: string format
      local _ = tostring(42)
    end, { duration=0.05, warmup=0.01, min_iters=10 })
    T.ok(result.iters >= 10, "got at least 10 iters")
    T.ok(result.mean_ns >= 0, "mean >= 0")
  end)

  T.it("real calibrate returns a number", function()
    local v = bench.calibrate({ iters=50 })
    T.ok(type(v) == "number", "calibrate returns number")
    T.ok(v >= 0, "calibrate >= 0")
  end)

end)
