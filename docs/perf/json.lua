-- docs/perf/json.lua
-- Benchmark: JSON encode/decode throughput for pure and ffi tiers.
-- Usage: luajit docs/perf/json.lua [N]
--   N = number of iterations per scenario (default auto-selected per scenario)

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local pure = require("lib.format.json.pure")
local ffi_impl = require("lib.format.json.ffi")
local json = require("lib.format.json")

-- NULL sentinel shared across tiers.
local NULL = json.null

-- ── Benchmark harness ─────────────────────────────────────────────────────────

local function bench(label, fn, iters)
    -- Warmup: 5% of iters, min 5.
    local warmup = math.max(5, math.floor(iters * 0.05))
    for _ = 1, warmup do fn() end

    -- 3 rounds; report best.
    local best_us = math.huge
    for _ = 1, 3 do
        collectgarbage("collect")
        collectgarbage("stop")
        local t0 = os.clock()
        for _ = 1, iters do fn() end
        local t1 = os.clock()
        collectgarbage("restart")
        local us = (t1 - t0) / iters * 1e6
        if us < best_us then best_us = us end
    end
    return best_us
end

local fmt = string.format

local function print_row(label, pure_us, ffi_us)
    local speedup = pure_us / ffi_us
    io.write(fmt("  %-42s  pure: %7.1f µs  ffi: %7.1f µs  speedup: %.2fx\n",
        label, pure_us, ffi_us, speedup))
end

-- ── Test data ─────────────────────────────────────────────────────────────────

-- Small object: 10 fields of mixed types.
local small_obj = {
    name   = "alice",
    age    = 30,
    active = true,
    score  = 98.6,
    tag    = "test",
    x      = 1,
    y      = 2,
    z      = 3,
    w      = 4,
    q      = 5,
}
local small_obj_str = pure._encode_raw(small_obj, NULL)

-- Large array: 1000 floating-point numbers.
local large_arr = {}
for i = 1, 1000 do large_arr[i] = i * 1.1 end
local large_arr_str = pure._encode_raw(large_arr, NULL)

-- Deeply nested: depth 50.
local function make_deep(depth)
    if depth == 0 then return { value = 42 } end
    return { child = make_deep(depth - 1), level = depth }
end
local deep_obj = make_deep(50)
local deep_str = pure._encode_raw(deep_obj, NULL)

-- Large string with escapes: 10 KB of text requiring escape processing.
local long_str_inner = string.rep("hello world \t\n \"test\" \\path\\ ", 200)
local long_str_val   = { text = long_str_inner }
local long_str_json  = pure._encode_raw(long_str_val, NULL)

-- ── Run benchmarks ────────────────────────────────────────────────────────────

print("=== JSON benchmark (" .. json._tier .. " tier selected) ===")
print(fmt("selected tier: %s", json._tier))
print("")

print("encode:")
print_row("small object (10 fields), 10000 iters",
    bench("pure enc small", function() pure._encode_raw(small_obj, NULL) end, 10000),
    bench("ffi enc small",  function() ffi_impl._encode_raw(small_obj, NULL) end, 10000))

print_row("large array (1000 numbers), 1000 iters",
    bench("pure enc arr", function() pure._encode_raw(large_arr, NULL) end, 1000),
    bench("ffi enc arr",  function() ffi_impl._encode_raw(large_arr, NULL) end, 1000))

print_row("deeply nested (depth 50), 1000 iters",
    bench("pure enc deep", function() pure._encode_raw(deep_obj, NULL) end, 1000),
    bench("ffi enc deep",  function() ffi_impl._encode_raw(deep_obj, NULL) end, 1000))

print_row("large string (10 KB with escapes), 1000 iters",
    bench("pure enc str", function() pure._encode_raw(long_str_val, NULL) end, 1000),
    bench("ffi enc str",  function() ffi_impl._encode_raw(long_str_val, NULL) end, 1000))

print("")
print("decode:")
print_row("small object (10 fields), 10000 iters",
    bench("pure dec small", function() pure._decode_raw(small_obj_str, NULL) end, 10000),
    bench("ffi dec small",  function() ffi_impl._decode_raw(small_obj_str, NULL) end, 10000))

print_row("large array (1000 numbers), 1000 iters",
    bench("pure dec arr", function() pure._decode_raw(large_arr_str, NULL) end, 1000),
    bench("ffi dec arr",  function() ffi_impl._decode_raw(large_arr_str, NULL) end, 1000))

print_row("deeply nested (depth 50), 1000 iters",
    bench("pure dec deep", function() pure._decode_raw(deep_str, NULL) end, 1000),
    bench("ffi dec deep",  function() ffi_impl._decode_raw(deep_str, NULL) end, 1000))

print_row("large string (10 KB with escapes), 1000 iters",
    bench("pure dec str", function() pure._decode_raw(long_str_json, NULL) end, 1000),
    bench("ffi dec str",  function() ffi_impl._decode_raw(long_str_json, NULL) end, 1000))

print("")
print(fmt("input sizes: small_obj=%d bytes  large_arr=%d bytes  deep=%d bytes  large_str=%d bytes",
    #small_obj_str, #large_arr_str, #deep_str, #long_str_json))
