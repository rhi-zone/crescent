-- docs/perf/v2_parse.lua
-- Benchmark: v2 parser throughput and allocation pressure.
-- Usage: luajit docs/perf/v2_parse.lua [N] [file ...]

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local v2 = require("lib.type.static.v2")

local function read_file(path)
    local f = io.open(path, "r")
    if not f then error("cannot open " .. path) end
    local s = f:read("*a")
    f:close()
    return s
end

local N = tonumber(arg[1]) or 500

local files
if arg[2] then
    files = {}
    for i = 2, #arg do
        files[i - 1] = arg[i]
    end
else
    files = {
        "lib/type/static/v2/lex.lua",
        "lib/type/static/v2/parse.lua",
        "lib/type/static/infer.lua",
    }
end

local fmt = string.format

for _, path in ipairs(files) do
    local src = read_file(path)
    local kb = #src / 1024

    -- Warmup
    for i = 1, 20 do v2.parse.parse(src, path) end

    -- 3 rounds
    local best_us = math.huge
    for round = 1, 3 do
        collectgarbage("collect")
        collectgarbage("stop")
        local mem0 = collectgarbage("count")
        local t0 = os.clock()
        for i = 1, N do
            v2.parse.parse(src, path)
        end
        local t1 = os.clock()
        local mem1 = collectgarbage("count")
        collectgarbage("restart")
        local us = (t1 - t0) / N * 1e6
        if us < best_us then best_us = us end
    end

    collectgarbage("collect")
    collectgarbage("stop")
    local mem0 = collectgarbage("count")
    for i = 1, N do
        v2.parse.parse(src, path)
    end
    local mem1 = collectgarbage("count")
    collectgarbage("restart")
    local kb_per = (mem1 - mem0) / N

    print(fmt("%-40s  %5.1f KB  %7.0f µs  %6.1f KB/parse  %5.1f MB/s",
        path, kb, best_us, kb_per, kb / best_us * 1e6 / 1024))
end
