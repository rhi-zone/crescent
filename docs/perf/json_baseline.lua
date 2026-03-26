-- docs/perf/json_baseline.lua
-- Baseline benchmark for lunajson (existing implementation).
-- Run BEFORE replacing lib/format/json/init.lua.
-- Usage: luajit docs/perf/json_baseline.lua

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

local function bench(label, fn, iters)
    -- warmup
    for i = 1, math.floor(iters * 0.05) do fn() end
    collectgarbage("collect")
    collectgarbage("stop")
    local t0 = os.clock()
    for i = 1, iters do fn() end
    local t1 = os.clock()
    collectgarbage("restart")
    local us = (t1 - t0) / iters * 1e6
    io.write(string.format("  %-40s  %7.1f µs/iter\n", label, us))
end

-- ── Test data ─────────────────────────────────────────────────────────────────

local small_obj = { name = "alice", age = 30, active = true,
    score = 98.6, tag = "test", x = 1, y = 2, z = 3, w = 4, q = 5 }
local small_obj_str = json._encode_raw(small_obj)

local large_arr = {}
for i = 1, 1000 do large_arr[i] = i * 1.1 end
local large_arr_str = json._encode_raw(large_arr)

local function make_deep(depth)
    if depth == 0 then return { value = 42 } end
    return { child = make_deep(depth - 1), level = depth }
end
local deep_obj = make_deep(50)
local deep_str = json._encode_raw(deep_obj)

local long_str_inner = string.rep("hello world \t\n \"test\" ", 500)
local long_str_val = { text = long_str_inner }
local long_str_json = json._encode_raw(long_str_val)

print("=== lunajson baseline ===")
print("encode:")
bench("small object (10 fields)", function() json._encode_raw(small_obj) end, 10000)
bench("large array (1000 numbers)", function() json._encode_raw(large_arr) end, 1000)
bench("deeply nested (depth 50)", function() json._encode_raw(deep_obj) end, 1000)
bench("large string (escapes)", function() json._encode_raw(long_str_val) end, 1000)
print("decode:")
bench("small object (10 fields)", function() json._decode_raw(small_obj_str) end, 10000)
bench("large array (1000 numbers)", function() json._decode_raw(large_arr_str) end, 1000)
bench("deeply nested (depth 50)", function() json._decode_raw(deep_str) end, 1000)
bench("large string (escapes)", function() json._decode_raw(long_str_json) end, 1000)
