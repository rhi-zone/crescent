-- lib/platform/projection_pipeline/projection_pipeline_test.lua
--
-- Tests for Slice 1 of the projection pipeline:
--   - Happy path: example_text.lua → hardened ESM TS string.
--   - Sad path:   a deliberately broken projection returns (nil, errmsg).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local pipeline = require("lib.platform.projection_pipeline")

local PROJECTION_DIR = "lib/platform/apps/system_dashboard/projections/"
local EXAMPLE_PATH   = PROJECTION_DIR .. "example_text.lua"

-- Mirrors the prelude stack documented in
-- lib/platform/apps/system_dashboard/projections/projection_types_test.lua —
-- the full globals a projection author sees.
local GLOBALS_FILES = {
    "lib/type/static/stdlib_types.lua",
    "lib/web/js_types.lua",
    "lib/platform/apps/system_dashboard/primitive_types.lua",
    PROJECTION_DIR .. "projection_types.lua",
}

-- ── 1. Happy path: a clean projection transpiles ────────────────────────────

T.describe("projection_pipeline: example_text.lua transpiles to hardened ESM", function()
    T.it("returns a non-empty TS string with expected constructs", function()
        local ts, err = pipeline.transpile_projection({
            source_path   = EXAMPLE_PATH,
            globals_files = GLOBALS_FILES,
        })
        T.eq(err, nil, "expected no error, got: " .. tostring(err))
        T.ok(ts ~= nil, "expected ts string, got nil")
        local out = ts --[[: string]]
        T.ok(#out > 0, "expected non-empty output")
        -- Hardened output prepends the __rec helper (null-proto records).
        T.ok(out:find("__rec", 1, true) ~= nil,
            "expected harden helper `__rec` in output")
        -- ESM module output: project_text is a `function` declaration emitted
        -- at module top-level by lua2ts.
        T.ok(out:find("function project_text", 1, true) ~= nil,
            "expected `function project_text` in output")
        -- No raw JS hazards should slip through (sanity — the typechecker
        -- already forbids `globalThis` etc. as undeclared identifiers, but
        -- harden mode is the second wall).
        T.ok(out:find("globalThis", 1, true) == nil,
            "harden output must not contain raw globalThis")
    end)
end)

-- ── 2. Sad path: a projection with a type error fails cleanly ───────────────

-- We write a temporary projection file under the projections directory so
-- relative require() resolution (if any) still works.  The file uses
-- `dom.marquee` — a tag the projection_types.lua allowlist deliberately
-- excludes — so the typechecker must reject it.
local BAD_PATH = PROJECTION_DIR .. "_pipeline_bad_tmp.lua"

local function write_bad_file()
    local f = assert(io.open(BAD_PATH, "w"))
    f:write([[
-- Temporary fixture for projection_pipeline test (auto-deleted).
--:: require "lib.platform.apps.system_dashboard.projections.projection_types"

--: (Text, Ctx) -> Element
local function project_bad(value, ctx)
    return dom.marquee({}, { value.text })
end

return project_bad
]])
    f:close()
end

local function remove_bad_file()
    os.remove(BAD_PATH)
end

T.describe("projection_pipeline: rejects projection with type error", function()
    T.it("returns (nil, errmsg) when typecheck fails", function()
        write_bad_file()
        local ts, err = pipeline.transpile_projection({
            source_path   = BAD_PATH,
            globals_files = GLOBALS_FILES,
        })
        remove_bad_file()
        T.eq(ts, nil, "expected nil ts on type error")
        T.ok(err ~= nil, "expected non-nil errmsg")
        local em = err --[[: string]]
        T.ok(#em > 0, "expected non-empty errmsg")
        T.ok(em:find("typecheck", 1, true) ~= nil,
            "expected errmsg to mention typecheck: " .. em)
    end)
end)
