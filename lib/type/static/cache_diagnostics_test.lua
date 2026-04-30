-- lib/type/static/cache_diagnostics_test.lua
-- Regression: input files with errors must report those errors on warm cache
-- hits (not just cold runs). The .cri schema (v2) carries diagnostics in
-- Section 7; the cache-hit branch in check.lua restores them into err_ctx so
-- the solver can be skipped while still surfacing the same errors.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T         = require("lib.test.assert")
local check_mod = require("lib.type.static.check")
local cri_write = require("lib.type.static.cri_write")
local cri_read  = require("lib.type.static.cri_read")
local errors_mod = require("lib.type.static.errors")

-- Use a unique scratch directory under .crescentcache so we don't disturb
-- the project's normal cache.
local SCRATCH_CACHE = ".crescentcache_test_diags"
local SCRATCH_FILE  = ".crescentcache_test_diags_subject.lua"

-- Source with a guaranteed checker error: assigning a string to a typed-as-integer local.
local SRC_WITH_ERROR = [[
local x --: integer
x = "not an integer"
return x
]]

local function rmrf(path)
    os.execute("rm -rf '" .. path .. "'")
end

local function write_file(path, contents)
    local f = assert(io.open(path, "w"))
    f:write(contents)
    f:close()
end

T.describe("cri schema v2: diagnostics serialization", function()
    T.it("serializes errors and notes round-trip", function()
        -- Build a minimal ctx via check_string so cri_write has a valid arena.
        local _, ctx = check_mod.check_string("return 1", "scratch.lua")
        T.ok(ctx ~= nil)

        local diag_in = {
            errors = {
                { kind = "error", filename = "a.lua", line = 3, col = 5,
                  msg = "boom",
                  notes = {
                    { filename = "a.lua", line = 1, col = 1, msg = "first defined here" },
                  },
                },
            },
            warnings = {
                { kind = "warning", filename = "a.lua", line = 7, col = 2,
                  msg = "watch out", notes = {} },
            },
        }
        local bytes = cri_write.serialize(ctx, {}, {}, diag_in)
        T.ok(#bytes >= 68, "v2 header is at least 68 bytes")

        local _, ctx2 = check_mod.check_string("return 1", "scratch2.lua")
        T.ok(ctx2 ~= nil)
        local ok, _exports, _aliases, errs, warns = cri_read.load(bytes, ctx2)
        T.ok(ok, "cri_read.load succeeded")
        T.ok(errs ~= nil, "errors decoded")
        T.eq(#errs, 1)
        T.eq(errs[1].filename, "a.lua")
        T.eq(errs[1].line, 3)
        T.eq(errs[1].col, 5)
        T.eq(errs[1].msg, "boom")
        T.eq(#errs[1].notes, 1)
        T.eq(errs[1].notes[1].msg, "first defined here")
        T.ok(warns ~= nil, "warnings decoded")
        T.eq(#warns, 1)
        T.eq(warns[1].msg, "watch out")
    end)

    T.it("omits diagnostics section when both lists empty", function()
        local _, ctx = check_mod.check_string("return 1", "scratch.lua")
        local bytes = cri_write.serialize(ctx, {}, {}, { errors = {}, warnings = {} })
        local _, ctx2 = check_mod.check_string("return 1", "scratch2.lua")
        local ok, _exp, _al, errs, warns = cri_read.load(bytes, ctx2)
        T.ok(ok)
        T.ok(errs == nil and warns == nil, "no diagnostics section when both empty")
    end)
end)

T.describe("incremental check: cache-hit preserves diagnostics", function()
    T.it("warm cache hit reports same errors as cold check", function()
        rmrf(SCRATCH_CACHE)
        rmrf(SCRATCH_FILE)
        write_file(SCRATCH_FILE, SRC_WITH_ERROR)

        check_mod.clear_cache()
        check_mod.set_cache_dir(SCRATCH_CACHE)

        -- Cold check: full solver run, diagnostics flow through err_ctx.
        local err1 = check_mod.check_file(SCRATCH_FILE, nil, nil, {})
        local cold_count = #err1.errors
        T.ok(cold_count > 0, "cold check should report at least one error")

        -- Force the disk cache flush so the .cri is persisted.
        require("lib.type.static.cache").flush()

        -- Drop the in-memory session cache so the next call re-loads from disk.
        check_mod.clear_cache()
        check_mod.set_cache_dir(SCRATCH_CACHE)

        -- Warm check: hash matches, solver is skipped, diagnostics restored.
        local err2 = check_mod.check_file(SCRATCH_FILE, nil, nil, {})
        local warm_count = #err2.errors
        T.eq(warm_count, cold_count)
        -- Spot-check that the restored diagnostic carries the same shape.
        T.eq(err2.errors[1].filename, err1.errors[1].filename)
        T.eq(err2.errors[1].line, err1.errors[1].line)
        T.eq(err2.errors[1].msg, err1.errors[1].msg)
        T.ok(err2.source_lines[SCRATCH_FILE] ~= nil,
             "source_lines populated for caret context after cache hit")

        rmrf(SCRATCH_CACHE)
        rmrf(SCRATCH_FILE)
        check_mod.clear_cache()
    end)
end)
