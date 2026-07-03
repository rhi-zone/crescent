-- lib/type/v9/smoke.lua
-- Whole-lib TOTALITY SMOKE + diagnostic histogram. Run from the repo root:
--
--   bin/cr lib/type/v9/smoke.lua
--
-- Two passes over every lib/**/*.lua file:
--   lower — parse + total lowering only (the totality claim: zero crashes,
--           every construct routed); deliberately DEP-LESS — totality needs
--           no summaries, so require sites read as the honest boundary;
--   full  — engine solve + obligation evaluation, through ONE SHARED
--           cross-module SESSION (check.session): module summaries resolve
--           on demand and each file is solved AT MOST ONCE per run (a file
--           already solved as someone's dep is served from the session
--           cache) — the sharing that keeps the whole-lib run near-linear
--           now checking one file may pull its transitive deps.
--
-- The histogram (counts by diagnostic code) is the honest coverage state
-- and the prioritized roadmap: which `unsupported:<construct>` buckets
-- dominate, and what the supported discipline finds. (July 2026, functions
-- + annotations: 1,560 files, zero crashes, full solve ~34s.) This is a TOOL
-- entry point (the edge), so it constructs its io caps here; the library it
-- drives (check.lua) only ever sees injected caps.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

--:: require "lib.type.v9.check"

local check = require("lib.type.v9.check")

--:: CDiag = { code: string, severity: string, message: string, line: integer, col: integer }

--: (string) -> (string | nil, string | nil)
local function read_file(path)
    local f = io.open(path, "r")
    if f == nil then return nil, path .. ": cannot open" end
    local s = f:read("*a")
    f:close()
    if s == nil then return nil, path .. ": cannot read" end
    return s, nil
end

--: () -> { [integer]: string }
local function list_lua_files()
    local files = {} --: { [integer]: string }
    local p = io.popen("find lib -type f -name '*.lua' | sort")
    if p == nil then return files end
    for line in p:lines() do
        if line ~= nil then files[#files + 1] = line end
    end
    p:close()
    return files
end

--: (mode: string, files: { [integer]: string }) -> nil
local function run_mode(mode, files)
    local caps = { read_file = read_file }
    -- ONE session for the whole full pass: summaries and solves are shared
    -- across every file (per-file sessions would re-solve shared deps).
    local session = nil --: Session | nil
    if mode == "full" then session = check.session(caps, nil) end
    local t0 = os.clock()
    local crashes = 0
    local total = 0
    local hist = {} --: { [string]: integer }
    --: (path: string) -> ({ [integer]: CDiag } | nil, string | nil, Summary | nil)
    local function check_one(path)
        if session ~= nil then return session.check_file(path) end
        return check.check_file(caps, path, { mode = mode, policy = nil, deps = nil })
    end
    for i = 1, #files do
        local path = files[i]
        local diags, err = check_one(path)
        if diags == nil then
            crashes = crashes + 1
            print(("CRASH %s: %s"):format(path, err or "?"))
        else
            total = total + #diags
            check.merge_histogram(hist, check.histogram(diags))
        end
    end
    print(("mode=%-5s files=%d crashes=%d diagnostics=%d time=%.2fs")
        :format(mode, #files, crashes, total, os.clock() - t0))
    local codes = {} --: { [integer]: string }
    for code in pairs(hist) do codes[#codes + 1] = code end
    table.sort(codes, function(a, b)
        if hist[a] ~= hist[b] then return hist[a] > hist[b] end
        return a < b
    end)
    for i = 1, #codes do
        print(("  %7d  %s"):format(hist[codes[i]], codes[i]))
    end
    return nil
end

local files = list_lua_files()
run_mode("lower", files)
run_mode("full", files)
