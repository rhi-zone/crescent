-- lib/type/static/v2/check.lua
-- Entry point for the v2 typechecker.
-- Orchestrates parse → annotations → prescan → infer → collect.

local infer_mod  = require("lib.type.static.v2.infer")
local errors_mod = require("lib.type.static.v2.errors")
local intern_mod = require("lib.type.static.v2.intern")
local env_mod    = require("lib.type.static.v2.env")

local M = {}

-- Module result cache: filename -> { err_ctx, scope }
-- Simple, no invalidation — for batch checking within one session.
local _cache = {}

-- Shared intern pool for check_files — lazy-initialised, reused across files.
local pool

-- Clear the module cache.
function M.clear_cache()
    _cache = {}
end

-- Check a source string and return an error context.
-- Optional pool can be shared across calls for interning efficiency.
function M.check_string(source, filename, parent_scope, pool)
    return infer_mod.check_string(source, filename, parent_scope, pool)
end

-- Check a file on disk and return an error context.
-- Results are cached by filename for module resolution.
function M.check_file(filename, parent_scope, pool)
    if _cache[filename] then
        return _cache[filename].err_ctx
    end

    local f, ioerr = io.open(filename, "r")
    if not f then
        local err_ctx = errors_mod.new_ctx()
        errors_mod.error(err_ctx, filename, 0, 0, "cannot open file: " .. (ioerr or filename))
        return err_ctx
    end
    local source = f:read("*a")
    f:close()

    local err_ctx = infer_mod.check_string(source, filename, parent_scope, pool)
    _cache[filename] = { err_ctx = err_ctx }
    return err_ctx
end

-- Check multiple files and return a combined error context.
-- Files share an intern pool for efficient string interning.
function M.check_files(filenames, parent_scope)
    pool = pool or intern_mod.new()
    local combined = errors_mod.new_ctx()
    for _, filename in ipairs(filenames) do
        local err_ctx = M.check_file(filename, parent_scope, pool)
        for _, e in ipairs(err_ctx.errors) do
            combined.errors[#combined.errors + 1] = e
        end
        for _, w in ipairs(err_ctx.warnings) do
            combined.warnings[#combined.warnings + 1] = w
        end
    end
    return combined
end

return M
