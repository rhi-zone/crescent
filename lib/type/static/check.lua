-- lib/type/static/check.lua
-- Entry point for the typechecker.
-- Orchestrates parse → annotations → prescan → infer → .cri cache.

local constrain_mod  = require("lib.type.static.constrain")
local solve_mod      = require("lib.type.static.solve")
local errors_mod     = require("lib.type.static.errors")
local intern_mod     = require("lib.type.static.intern")
local env_mod        = require("lib.type.static.env")
local types_mod      = require("lib.type.static.types")
local cache_mod      = require("lib.type.static.cache")
local cri_write      = require("lib.type.static.cri_write")
local cri_read       = require("lib.type.static.cri_read")

local M = {}

-- ---------------------------------------------------------------------------
-- v3 inference core (constraint generation + solving)
-- ---------------------------------------------------------------------------
local function run_v3(source, filename, parent_scope, pool, cri_loader, opts)
    local ctx, constraints = constrain_mod.generate(source, filename, parent_scope, pool, cri_loader, opts)
    solve_mod.solve(ctx, constraints)
    return ctx.err, ctx
end

-- Session cache: absolute_filename → { err_ctx, ctx, export_tid, cri_bytes }
-- Simple per-session, no invalidation. Cleared by M.clear_cache().
--:: SessionEntry = { err_ctx: ErrCtx, ctx: Ctx | nil, export_tid: integer | nil, cri_bytes: string | nil }
--: { [string]: SessionEntry | nil, ... }
local _session = {}

-- Currently-being-checked set: prevents re-entrant check_file calls.
--: { [string]: boolean | nil, ... }
local _checking = {}

-- Shared intern pool for multi-file sessions — lazy-initialised.
local _pool

-- Clear the session cache.
function M.clear_cache()
    _session  = {}
    _checking = {}
    _pool     = nil
end

-- Invalidate the session cache entry for a single file.
-- Useful in the LSP: when a file is edited, only its entry needs eviction;
-- deps on disk are still valid and can be reused.
function M.invalidate_file(filename)
    if filename:sub(1, 2) == "./" then filename = filename:sub(3) end
    _session[filename]  = nil
    _checking[filename] = nil
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

-- Extract file-level type aliases from ctx.scope for CRI serialization.
-- Returns an array of { name, body, params, nominal, resolved_bounds }.
-- Only collects aliases from the file's own scope (not prelude/parent).
local function extract_type_aliases(ctx)
    local result = {}
    local scope = ctx.scope
    if not scope or not scope.type_bindings then return result end
    for name_id, alias in pairs(scope.type_bindings) do
        -- pairs() returns unknown values even over { [integer]: TypeAlias } tables;
        -- `any` is required so field access on `al` compiles. TypeAlias is the actual type.
        --: any
        local al = alias
        if al and al.body then
            local name = intern_mod.get(ctx.pool, name_id)
            if name then
                local params_strs = nil
                if al.params and #al.params > 0 then
                    params_strs = {}
                    for _, pid in ipairs(al.params) do
                        params_strs[#params_strs + 1] = intern_mod.get(ctx.pool, pid) or ""
                    end
                end
                local bounds = nil
                if al.resolved_bounds then
                    bounds = {}
                    for j, bid in ipairs(al.resolved_bounds) do
                        bounds[j] = bid  -- type_id or nil
                    end
                end
                result[#result + 1] = {
                    name = name,
                    body = al.body,
                    params = params_strs,
                    nominal = al.nominal or false,
                    resolved_bounds = bounds,
                }
            end
        end
    end
    -- Sort by name for deterministic serialization.
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
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

-- Given a resolved module file path, return the companion declaration path
-- if it exists on disk, otherwise nil.
-- Convention: lib/foo/init.lua  → lib/foo/init_types.lua (preferred) or lib/foo/init.d.lua
--             lib/foo.lua       → lib/foo_types.lua (preferred) or lib/foo.d.lua
local function find_decl_path(src_path)
    if src_path:sub(-4) ~= ".lua" then return nil end
    local base = src_path:sub(1, -5)
    -- Prefer _types.lua convention; fall back to legacy .d.lua
    local types = base .. "_types.lua"
    local f = io.open(types, "r")
    if f then f:close(); return types end
    local d = base .. ".d.lua"
    local g = io.open(d, "r")
    if g then g:close(); return d end
    return nil
end

-- ---------------------------------------------------------------------------
-- check_string
-- ---------------------------------------------------------------------------
-- Check a source string and return err_ctx, ctx.
-- Optional pool can be shared across calls for interning efficiency.
-- Optional cri_loader: function(ctx, mod_name) -> type_id | nil
-- Installed on ctx before inference so require() calls resolve.
-- Optional opts table:
--   opts.globals_files: list of file paths loaded as global declarations instead
--     of the default stdlib_types.lua. Only used when parent_scope is nil.
function M.check_string(source, filename, parent_scope, pool, cri_loader, opts)
    return run_v3(source, filename, parent_scope, pool, cri_loader, opts)
end

-- ---------------------------------------------------------------------------
-- check_file  (with .cri cache integration)
-- ---------------------------------------------------------------------------
-- Check a file on disk. Returns err_ctx, ctx.
-- Shares the session pool across calls.
-- If the disk cache is enabled, attempts a cache hit before checking.
-- Records the file's export_tid in the session cache for require() resolution.
--: (string, Scope | nil, InternPool | nil) -> (ErrCtx, Ctx | nil)
function M.check_file(filename, parent_scope, explicit_pool, opts)
    -- Normalise path (basic: strip leading "./" only)
    if filename:sub(1, 2) == "./" then filename = filename:sub(3) end

    --: SessionEntry | nil
    local cached = _session[filename]
    if cached then
        return cached.err_ctx, cached.ctx
    end
    -- Prevent re-entrant checks (circular require chains).
    if _checking[filename] then
        local err_ctx = errors_mod.new_ctx()
        return err_ctx, nil
    end

    _pool = explicit_pool or _pool or intern_mod.new()
    _checking[filename] = true

    -- Build a cri_loader for require() type resolution.
    -- Recursively checks dependencies and caches their export types.
    local function cri_loader(ctx, mod_name)
        local dep_path = resolve_module_path(mod_name)
        -- Try init.lua if the direct path doesn't exist:
        -- lib/foo.lua → lib/foo/init.lua (standard Lua package convention).
        local f = io.open(dep_path, "r")
        if f then
            f:close()
        else
            local init_path = dep_path:gsub("%.lua$", "/init.lua")
            f = io.open(init_path, "r")
            if f then f:close(); dep_path = init_path end
        end
        -- Prefer a companion _types.lua declaration file when present.
        -- e.g. lib/lunajson/init_types.lua overrides lib/lunajson/init.lua for typing.
        local decl = find_decl_path(dep_path)
        if decl then dep_path = decl end

        -- Guard: skip if the dependency is currently being checked (cycle prevention).
        if _checking[dep_path] then return nil end

        -- Check session cache first.
        -- Type IDs are arena-local: never return a dep_ctx type ID directly.
        -- Always do a cri round-trip to get a type ID in the current ctx's arena.

        -- Check session cache: if dep has cri_bytes, deserialise into current ctx.
        local function load_and_tag(cri_bytes, source_file)
            local before = ctx.types.len
            local ok, exports, aliases = cri_read.load(cri_bytes, ctx)
            if ok and exports["__ret"] then
                -- Mark all type IDs created by this load as originating from source_file.
                if ctx.type_origins then
                    for i = before, ctx.types.len - 1 do
                        ctx.type_origins[i] = source_file
                    end
                end
                return exports["__ret"], aliases
            end
            return nil, nil
        end

        if _session[dep_path] then
            local dep = _session[dep_path]
            local cri = dep.cri_bytes
            if cri then
                local ret, aliases = load_and_tag(cri, dep_path)
                if ret then return ret, aliases end
            end
            -- Dep was checked but has no serializable export (e.g. T_ANY): return nil.
            return nil
        end

        -- Check the dependency (may recursively resolve its own require()s).
        local _, dep_ctx = M.check_file(dep_path, parent_scope, _pool, opts)
        if dep_ctx then
            -- Session entry was populated by check_file; retry via session cache.
            local dep2 = _session[dep_path]
            if dep2 then
                local cri2 = dep2.cri_bytes
                if cri2 then
                    local ret, aliases = load_and_tag(cri2, dep_path)
                    if ret then return ret, aliases end
                end
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
            err_ctx, ctx = run_v3("", filename, parent_scope, _pool, cri_loader, opts)
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
        _session[filename] = { err_ctx = err_ctx, ctx = nil, export_tid = nil, cri_bytes = nil }
        return err_ctx, nil
    end
    local source = f:read("*a")
    f:close()

    err_ctx, ctx = run_v3(source, filename, parent_scope, _pool, cri_loader, opts)

    local export_tid = ctx and extract_export_tid(ctx) or nil

    -- Serialize to .cri and store in disk cache.
    -- pcall second return is unknown; `any` is required so the value can be stored and
    -- passed to cache_mod.store (which expects string) without a static type error.
    local cri_bytes_stored = nil --: any
    if ctx and export_tid and export_tid ~= ctx.T_ANY then
        local exp_map = { ["__ret"] = export_tid }
        local alias_list = ctx and extract_type_aliases(ctx) or {}
        local ok_ser, cri_bytes = pcall(cri_write.serialize, ctx, exp_map, alias_list)
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
-- check_string_with_deps
-- ---------------------------------------------------------------------------
-- Check a source string (e.g. an unsaved editor buffer) with one level of
-- require() dependency resolution: dependencies are read from disk via
-- check_file so their export types are available to the caller.
-- Unlike check_file's internal cri_loader, this does not require _disk_cache_dir.
-- Use this in the LSP to check buffers that may differ from the on-disk file.
function M.check_string_with_deps(source, filename, parent_scope, opts)
    if filename:sub(1, 2) == "./" then filename = filename:sub(3) end
    _pool = _pool or intern_mod.new()

    -- Guard against cycles within our own cri_loader calls.
    local checking_deps = {}

    local function try_dep(ctx, dep_path)
        if checking_deps[dep_path] or _checking[dep_path] then return nil end
        checking_deps[dep_path] = true
        M.check_file(dep_path, parent_scope, _pool, opts)
        checking_deps[dep_path] = nil
        if _session[dep_path] and _session[dep_path].cri_bytes then
            local ok, exports, aliases = cri_read.load(_session[dep_path].cri_bytes, ctx)
            if ok and exports["__ret"] then return exports["__ret"], aliases end
        end
        return nil
    end

    local function cri_loader(ctx, mod_name)
        -- Prefer _types.lua declaration file when present; fall back to .lua / init.lua.
        local rel = mod_name:gsub("%.", "/")
        local decl_flat = find_decl_path(rel .. ".lua")
        if decl_flat then return try_dep(ctx, decl_flat) end
        local decl_init = find_decl_path(rel .. "/init.lua")
        if decl_init then return try_dep(ctx, decl_init) end
        local ret, aliases = try_dep(ctx, rel .. ".lua")
        if ret then return ret, aliases end
        return try_dep(ctx, rel .. "/init.lua")
    end

    return run_v3(source, filename, parent_scope, _pool, cri_loader, opts)
end

-- ---------------------------------------------------------------------------
-- check_string_v3
-- ---------------------------------------------------------------------------
-- Alias for check_string (now that v3 is the default pipeline).
-- Kept for compatibility with callers that explicitly request v3.
M.check_string_v3 = M.check_string

-- ---------------------------------------------------------------------------
-- check_files
-- ---------------------------------------------------------------------------
-- Check multiple files and return a combined error context.
-- Files share an intern pool for efficient string interning.
--: ({ [integer]: string, ... }, Scope | nil) -> ErrCtx
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
