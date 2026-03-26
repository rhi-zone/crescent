-- docs/perf/run_all.lua
-- Run all lib/*/bench.lua scripts and summarise results.
-- Use this to spot perf regressions before committing.
--
-- Usage:
--   luajit docs/perf/run_all.lua          -- run all benches
--   luajit docs/perf/run_all.lua base64   -- run only matching benches

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local filter = arg and arg[1]

-- Discover bench scripts: lib/*/bench.lua and lib/*/*/bench.lua
local scripts = {}
local function discover(pattern)
    local f = io.popen("find lib -name bench.lua | sort")
    if not f then return end
    for line in f:lines() do
        table.insert(scripts, line)
    end
    f:close()
end
discover()

if #scripts == 0 then
    io.write("no bench.lua scripts found under lib/\n")
    os.exit(1)
end

local passed, failed = 0, 0
local sep = string.rep("─", 72)

io.write(string.format("\n%s\n  crescent perf suite\n%s\n\n", sep, sep))

for _, path in ipairs(scripts) do
    -- apply filter if given
    if filter and not path:find(filter, 1, true) then
        goto continue
    end

    io.write(string.format("▶  %s\n%s\n", path, sep))
    io.flush()

    -- run in a subprocess so each bench gets a clean JIT state
    local ok = os.execute("luajit " .. path)
    if ok == true or ok == 0 then
        passed = passed + 1
    else
        io.write(string.format("   FAILED (exit %s)\n", tostring(ok)))
        failed = failed + 1
    end
    io.write(sep .. "\n\n")
    io.flush()

    ::continue::
end

io.write(string.format(
    "%d bench(es) passed, %d failed\n\n", passed, failed))

os.exit(failed > 0 and 1 or 0)
