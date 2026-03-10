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
--   cache.set_dir(path)         -- set cache directory (default: ".crescentcache")
--   cache.lookup(src_hash)      -- returns cri_bytes or nil
--   cache.store(src_hash, cri_bytes) -- stores .cri and updates manifest
--   cache.invalidate(src_hash)  -- removes manifest entry (does not delete .cri)

local sha256 = require("lib.type.static.sha256")

local M = {}

local _dir = ".crescentcache"

-- Set the cache directory path.
function M.set_dir(path)
    _dir = path
end

-- Ensure the cache directory exists.
local function ensure_dir()
    os.execute("mkdir -p " .. _dir)
end

-- Manifest path.
local function manifest_path()
    return _dir .. "/manifest.lua"
end

-- Load the manifest table. Returns {} on failure.
local function load_manifest()
    local path = manifest_path()
    local fn, err = loadfile(path)
    if not fn then return {} end
    local ok, result = pcall(fn)
    if not ok or type(result) ~= "table" then return {} end
    return result
end

-- Write the manifest table as a Lua file.
local function save_manifest(t)
    local path = manifest_path()
    local f, err = io.open(path, "w")
    if not f then
        return false, "cannot write manifest: " .. (err or path)
    end
    f:write("return {\n")
    -- Sort keys for determinism
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        -- Both key and value are SHA-256 hex strings (64 chars, safe to quote).
        f:write(string.format("  [%q] = %q,\n", k, t[k]))
    end
    f:write("}\n")
    f:close()
    return true
end

-- Extract the content hash from .cri bytes (the 32-byte hash at offset 12).
-- Returns a 64-character lowercase hex string.
local function cri_content_hash(bytes)
    -- The SHA-256 was computed over the file with the hash field zeroed,
    -- then written into bytes 13-44 (1-based).  We read it back directly.
    -- (Could re-verify, but we trust the writer here.)
    local hex = {}
    for i = 13, 44 do
        hex[#hex + 1] = string.format("%02x", bytes:byte(i))
    end
    return table.concat(hex)
end

-- Look up a source hash in the manifest and return the cached .cri bytes.
-- Returns cri_bytes (string) on cache hit, or nil on miss.
function M.lookup(src_hash)
    local manifest = load_manifest()
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

-- Store .cri bytes in the cache and update the manifest.
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

    -- Update manifest.
    local manifest = load_manifest()
    manifest[src_hash] = cri_hash
    local ok, err = save_manifest(manifest)
    if not ok then return false, err end

    return true, cri_hash
end

-- Remove a manifest entry (e.g. on source change). Does not delete the .cri file
-- since other sources may reference the same content hash.
function M.invalidate(src_hash)
    local manifest = load_manifest()
    if manifest[src_hash] then
        manifest[src_hash] = nil
        save_manifest(manifest)
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
