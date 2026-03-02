-- lib/type/static/v2/check.lua
-- Entry point for the v2 typechecker.
-- Orchestrates parse → annotations → prescan → infer → .cri cache.

local infer_mod  = require("lib.type.static.v2.infer")
local errors_mod = require("lib.type.static.v2.errors")
local intern_mod = require("lib.type.static.v2.intern")
local env_mod    = require("lib.type.static.v2.env")
local types_mod  = require("lib.type.static.v2.types")
local cache_mod  = require("lib.type.static.v2.cache")
local cri_write  = require("lib.type.static.v2.cri_write")
local cri_read   = require("lib.type.static.v2.cri_read")

local M = {}

-- Session cache: absolute_filename → { err_ctx, ctx, export_tid }
-- Simple per-session, no invalidation. Cleared by M.clear_cache().
local _session = {}

-- Currently-being-checked set: prevents re-entrant check_file calls.
local _checking = {}

-- Shared intern pool for multi-file sessions — lazy-initialised.
local _pool

-- Clear the session cache.
function M.clear_cache()
    _session  = {}
    _checking = {}
    _pool     = nil
end

-- Enable or disable the disk .cri cache.
-- Pass a directory path to enable (default disabled).
-- Setting nil or false disables.
local _disk_cache_dir = nil
function M.set_cache_dir(dir)
    _disk_cache_dir = dir
    if dir then cache_mod.set_dir(dir) end
end

-- ---------------------------------------------------------------------------
-- Module export extraction
-- ---------------------------------------------------------------------------
-- Returns the type_id of the module's first return value (what `require()` gives).
-- Returns ctx.T_ANY if the module has no return statement.
local function extract_export_tid(ctx)
    local rets = ctx.module_return_tids
    if rets and #rets > 0 and rets[1] and #rets[1] > 0 then
        return types_mod.find(ctx, rets[1][1])
    end
    return ctx.T_ANY
end

-- ---------------------------------------------------------------------------
-- Module name → file path resolution
-- Translates a Lua module name ("a.b.c") to a relative path ("a/b/c.lua").
-- Returns the path string (not guaranteed to exist).
-- ---------------------------------------------------------------------------
local function resolve_module_path(mod_name)
    -- Replace "." with "/" and append ".lua"
    local path = mod_name:gsub("%.", "/") .. ".lua"
    return path
end

-- ---------------------------------------------------------------------------
-- check_string
-- ---------------------------------------------------------------------------
-- Check a source string and return err_ctx, ctx.
-- Optional pool can be shared across calls for interning efficiency.
-- Optional cri_loader: function(ctx, mod_name) -> type_id | nil
-- Installed on ctx before inference so require() calls resolve.
function M.check_string(source, filename, parent_scope, pool, cri_loader)
    return infer_mod.check_string(source, filename, parent_scope, pool, cri_loader)
end

-- ---------------------------------------------------------------------------
-- check_file  (with .cri cache integration)
-- ---------------------------------------------------------------------------
-- Check a file on disk. Returns err_ctx, ctx.
-- Shares the session pool across calls.
-- If the disk cache is enabled, attempts a cache hit before checking.
-- Records the file's export_tid in the session cache for require() resolution.
function M.check_file(filename, parent_scope, explicit_pool)
    -- Normalise path (basic: strip leading "./" only)
    if filename:sub(1, 2) == "./" then filename = filename:sub(3) end

    if _session[filename] then
        local s = _session[filename]
        return s.err_ctx, s.ctx
    end
    -- Prevent re-entrant checks (circular require chains).
    if _checking[filename] then
        local err_ctx = errors_mod.new_ctx()
        return err_ctx, nil
    end

    _pool = explicit_pool or _pool or intern_mod.new()
    _checking[filename] = true

    -- Build a cri_loader for require() type resolution.
    -- Only activated when _disk_cache_dir is set; otherwise checking would cascade
    -- recursively into every dependency and produce many false positives.
    local function cri_loader(ctx, mod_name)
        if not _disk_cache_dir then return nil end
        local dep_path = resolve_module_path(mod_name)

        -- Guard: skip if the dependency is currently being checked (cycle prevention).
        if _checking[dep_path] then return nil end

        -- Check session cache first.
        -- Type IDs are arena-local: never return a dep_ctx type ID directly.
        -- Always do a cri round-trip to get a type ID in the current ctx's arena.

        -- Check session cache: if dep has cri_bytes, deserialise into current ctx.
        if _session[dep_path] then
            local dep = _session[dep_path]
            if dep.cri_bytes then
                local ok, exports = cri_read.load(dep.cri_bytes, ctx)
                if ok and exports["__ret"] then return exports["__ret"] end
            end
            -- Dep was checked but has no serializable export (e.g. T_ANY): return nil.
            return nil
        end

        -- Check the dependency (may recursively resolve its own require()s).
        local _, dep_ctx = M.check_file(dep_path, parent_scope, _pool)
        if dep_ctx then
            -- Session entry was populated by check_file; retry via session cache.
            if _session[dep_path] and _session[dep_path].cri_bytes then
                local ok, exports = cri_read.load(_session[dep_path].cri_bytes, ctx)
                if ok and exports["__ret"] then return exports["__ret"] end
            end
        end

        return nil  -- dependency unresolvable: require() returns T_ANY
    end

    -- Try disk cache for this file.
    local src_hash
    if _disk_cache_dir then
        src_hash = cache_mod.hash_file(filename)
    end

    local err_ctx, ctx

    if src_hash then
        local cached_bytes = cache_mod.lookup(src_hash)
        if cached_bytes then
            err_ctx = errors_mod.new_ctx()
            err_ctx, ctx = infer_mod.check_string("", filename, parent_scope, _pool, cri_loader)
            local ok, exports = cri_read.load(cached_bytes, ctx)
            if ok and exports["__ret"] then
                local export_tid = exports["__ret"]
                _checking[filename] = nil
                _session[filename] = {
                    err_ctx = err_ctx, ctx = ctx,
                    export_tid = export_tid, cri_bytes = cached_bytes
                }
                return err_ctx, ctx
            end
            -- Cache load failed: fall through to full check.
        end
    end

    -- Full check.
    local f, ioerr = io.open(filename, "r")
    if not f then
        err_ctx = errors_mod.new_ctx()
        errors_mod.error(err_ctx, filename, 0, 0, "cannot open file: " .. (ioerr or filename))
        _checking[filename] = nil
        _session[filename] = { err_ctx = err_ctx, ctx = nil, export_tid = nil }
        return err_ctx, nil
    end
    local source = f:read("*a")
    f:close()

    err_ctx, ctx = infer_mod.check_string(source, filename, parent_scope, _pool, cri_loader)

    local export_tid = ctx and extract_export_tid(ctx) or nil

    -- Serialize to .cri and store in disk cache.
    local cri_bytes_stored = nil
    if ctx and export_tid and export_tid ~= ctx.T_ANY then
        local exp_map = { ["__ret"] = export_tid }
        local ok_ser, cri_bytes = pcall(cri_write.serialize, ctx, exp_map)
        if ok_ser then
            cri_bytes_stored = cri_bytes
            if src_hash then
                cache_mod.store(src_hash, cri_bytes)
            end
        end
    end

    _checking[filename] = nil
    _session[filename] = {
        err_ctx = err_ctx, ctx = ctx,
        export_tid = export_tid, cri_bytes = cri_bytes_stored
    }
    return err_ctx, ctx
end

-- ---------------------------------------------------------------------------
-- check_files
-- ---------------------------------------------------------------------------
-- Check multiple files and return a combined error context.
-- Files share an intern pool for efficient string interning.
function M.check_files(filenames, parent_scope)
    _pool = _pool or intern_mod.new()
    local combined = errors_mod.new_ctx()
    for _, filename in ipairs(filenames) do
        local err_ctx = M.check_file(filename, parent_scope, _pool)
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
