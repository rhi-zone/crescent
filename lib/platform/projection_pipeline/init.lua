-- lib/platform/projection_pipeline/init.lua
--
-- Slice 1 of the projection pipeline.
--
-- Pure function from (Lua projection source path, prelude globals) to the
-- hardened TypeScript string that the browser projection registry consumes.
-- No caching, no daemon integration, no mtime watching — later slices.
--
-- Capability model: the typechecker (`lib.type.static.check.check_file`) and
-- the transpiler (`lib.lua2ts`) already encapsulate their disk I/O.  The
-- pipeline therefore does not need a separate `read_file` cap; the caller
-- supplies file *paths*, and both passes resolve them through the existing
-- check/transpile entry points.  The injected capability is `globals_files`:
-- the list of prelude declaration files to load as globals for the
-- typechecker.  Callers (CLI, daemon, tests) decide that list — the pipeline
-- does not hardcode it.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local check_mod  = require("lib.type.static.check")
local errors_mod = require("lib.type.static.errors")
local lua2ts     = require("lib.lua2ts")

local M = {}

-- ---------------------------------------------------------------------------
-- transpile_projection
-- ---------------------------------------------------------------------------
-- Steps:
--   1. Typecheck `opts.source_path` with `opts.globals_files` as the prelude.
--      If the typechecker reports any errors, return (nil, formatted-errors).
--   2. Read the source from disk (via lua2ts.transpile_file) and transpile
--      with `{ harden = true, module = "esm", filename = opts.source_path }`.
--   3. Return (ts_string, nil) on success; (nil, errmsg) on failure.
--
-- Returns (string, nil) on success, (nil, errmsg) on failure (crescent
-- convention: never throws on data errors).
--: (opts: { source_path: string, globals_files: { [integer]: string, ... } }) -> (string | nil, string | nil)
function M.transpile_projection(opts)
    local source_path = opts.source_path
    local globals_files = opts.globals_files

    -- 1. Typecheck.
    -- check_file's session cache is keyed by absolute filename; we clear it so
    -- repeat calls on the same path don't reuse stale results across
    -- prelude-list changes.  This is cheap (no disk cache) and keeps the
    -- function pure from the caller's perspective.
    check_mod.clear_cache()
    local err_ctx, ctx = check_mod.check_file(source_path, nil, nil,
        { globals_files = globals_files, no_disk_cache = true })
    if not ctx then
        return nil, "typecheck failed for " .. source_path .. ":\n" ..
            errors_mod.format_plain(err_ctx)
    end
    if #err_ctx.errors > 0 then
        return nil, "typecheck errors in " .. source_path .. ":\n" ..
            errors_mod.format_plain(err_ctx)
    end

    -- 2. Transpile (lua2ts.transpile_file reads the source itself).
    --: { filename: string | nil, module: string | nil, strict: boolean | nil, harden: boolean | nil, bundle_mode: boolean | nil }
    local transpile_opts = {
        filename   = source_path,
        module     = "esm",
        strict     = nil,
        harden     = true,
        bundle_mode = nil,
    }
    local ts, terr = lua2ts.transpile_file(source_path, transpile_opts)
    if not ts then
        return nil, "transpile failed for " .. source_path .. ": " .. (terr or "?")
    end
    return ts, nil
end

return M
