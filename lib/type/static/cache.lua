-- lib/type/static/cache.lua
-- Content-addressed .cri interface cache.
--
-- Cache layout:
--   .crescentcache/
--     <sha256hex>.cri    ← .cri file named by SHA-256 of its content
--     manifest.lua       ← source_hash → cri_hash table (loadable chunk)
--
-- The manifest is a Lua file returning a table; it's loaded with loadfile()
-- for simplicity and written as a plain Lua table literal.
--
-- API:
--   local cache = require("lib.type.static.cache")
--   cache.set_dir(path)              -- set cache directory (default: ".crescentcache")
--   cache.lookup(src_hash)           -- returns cri_bytes or nil
--   cache.store(src_hash, cri_bytes) -- stores .cri and queues manifest update
--   cache.flush([shard_path])        -- write manifest to disk; shard_path writes a
--                                    --   shard instead of canonical manifest (parallel use)
--   cache.merge_shards(dir)          -- merge manifest.shard.*.lua files into manifest.lua
--   cache.invalidate(src_hash)       -- removes manifest entry

local sha256 = require("lib.type.static.sha256")

local M = {}

local _dir = ".crescentcache"

-- In-memory manifest: loaded once on first access, flushed at end of session.
-- nil = not yet loaded.
local _manifest = nil
local _manifest_dirty = false

-- Set the cache directory path. Clears any in-memory manifest.
function M.set_dir(path)
    _dir = path
    _manifest = nil
    _manifest_dirty = false
end

-- Ensure the cache directory exists.
local function ensure_dir()
    os.execute("mkdir -p " .. _dir)
end

-- Manifest path.
local function manifest_path()
    return _dir .. "/manifest.lua"
end

-- Load the manifest from disk. Returns {} on failure.
local function load_manifest_disk()
    local path = manifest_path()
    local fn = loadfile(path)
    if not fn then return {} end
    local ok, result = pcall(fn)
    if not ok or type(result) ~= "table" then return {} end
    return result
end

-- Return the in-memory manifest, loading from disk on first access.
local function get_manifest()
    if not _manifest then
        _manifest = load_manifest_disk()
    end
    return _manifest
end

-- Write the manifest table as a Lua file.
-- If path is nil, uses the canonical manifest path.
local function write_manifest_disk(t, path)
    path = path or manifest_path()
    local f = io.open(path, "w")
    if not f then return false end
    f:write("return {\n")
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        f:write(string.format("  [%q] = %q,\n", k, t[k]))
    end
    f:write("}\n")
    f:close()
    return true
end

-- Extract the content hash from .cri bytes (the 32-byte hash at offset 12).
-- Returns a 64-character lowercase hex string.
local function cri_content_hash(bytes)
    local hex = {}
    for i = 13, 44 do
        hex[#hex + 1] = string.format("%02x", bytes:byte(i))
    end
    return table.concat(hex)
end

-- Look up a source hash in the manifest and return the cached .cri bytes.
-- Returns cri_bytes (string) on cache hit, or nil on miss.
function M.lookup(src_hash)
    local manifest = get_manifest()
    local cri_hash = manifest[src_hash]
    if not cri_hash then return nil end

    local cri_path = _dir .. "/" .. cri_hash .. ".cri"
    local f = io.open(cri_path, "rb")
    if not f then return nil end
    local bytes = f:read("*a")
    f:close()

    if not bytes or #bytes < 64 then return nil end
    return bytes
end

-- Store .cri bytes in the cache and queue a manifest update.
-- The manifest is NOT written to disk until M.flush() is called.
-- src_hash: SHA-256 hex of the source file that produced this .cri.
-- cri_bytes: raw .cri binary string.
-- Returns true on success, or false + error message on failure.
function M.store(src_hash, cri_bytes)
    ensure_dir()

    local cri_hash = cri_content_hash(cri_bytes)
    local cri_path = _dir .. "/" .. cri_hash .. ".cri"

    -- Write .cri file (only if not already present — content-addressed so idempotent).
    local existing = io.open(cri_path, "rb")
    if existing then
        existing:close()
    else
        local f, err = io.open(cri_path, "wb")
        if not f then
            return false, "cannot write .cri: " .. (err or cri_path)
        end
        f:write(cri_bytes)
        f:close()
    end

    -- Update in-memory manifest. Flushed to disk by M.flush().
    local manifest = get_manifest()
    manifest[src_hash] = cri_hash
    _manifest_dirty = true

    return true, cri_hash
end

-- Write the in-memory manifest to disk if it has been modified.
-- If shard_path is provided, write to that path instead of the canonical
-- manifest path. Used by parallel workers: each worker writes its own shard,
-- the parent merges them with M.merge_shards().
-- Call once at the end of a CLI session (or at the end of a worker).
function M.flush(shard_path)
    if _manifest and _manifest_dirty then
        ensure_dir()
        if shard_path then
            write_manifest_disk(_manifest, shard_path)
        else
            write_manifest_disk(_manifest)
        end
        _manifest_dirty = false
    end
end

-- Merge all manifest.shard.*.lua files in dir into the canonical manifest.lua,
-- then delete the shard files. Safe to call after all workers have exited.
function M.merge_shards(dir)
    local manifest_file = (dir or _dir) .. "/manifest.lua"
    -- Load the current canonical manifest (may already exist).
    local fn = loadfile(manifest_file)
    local base = {}
    if fn then
        local ok, result = pcall(fn)
        if ok and type(result) == "table" then base = result end
    end

    -- Find and merge shard files. Use find via io.popen (no FFI needed here).
    local shard_pattern = (dir or _dir) .. "/manifest.shard.*.lua"
    local p = io.popen('ls ' .. shard_pattern .. ' 2>/dev/null')
    if p then
        local shard_files = {}
        for path in p:lines() do
            shard_files[#shard_files + 1] = path
        end
        p:close()

        local dirty = false
        for _, shard_path in ipairs(shard_files) do
            local sfn = loadfile(shard_path)
            if sfn then
                local ok, shard = pcall(sfn)
                if ok and type(shard) == "table" then
                    for k, v in pairs(shard) do
                        base[k] = v
                        dirty = true
                    end
                end
            end
            os.remove(shard_path)
        end

        if dirty then
            write_manifest_disk(base, manifest_file)
        end
    end
end

-- Remove a manifest entry (e.g. on source change). Does not delete the .cri file
-- since other sources may reference the same content hash.
function M.invalidate(src_hash)
    local manifest = get_manifest()
    if manifest[src_hash] then
        manifest[src_hash] = nil
        _manifest_dirty = true
    end
end

-- Hash a source file's content for use as manifest key.
-- Returns a 64-character SHA-256 hex string, or nil + error on failure.
function M.hash_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, "cannot open: " .. (err or path) end
    local src = f:read("*a")
    f:close()
    if not src then return nil, "cannot read: " .. path end
    return sha256.hash(src)
end

-- Hash a source string directly.
function M.hash_source(src)
    return sha256.hash(src)
end

return M
