-- lib/type/static/v2/intern.lua
-- String interning with FFI-aware hash table.
-- Hot path (intern_raw) does zero Lua string allocation — hashes raw
-- source bytes, probes open-addressing table, memcmp to confirm.
-- IDs start at 0; keywords pre-interned at 0..NUM_KEYWORDS-1.

local ffi = require("ffi")
local band = bit.band
local bxor = bit.bxor
local lshift = bit.lshift
local tobit = bit.tobit

local defs = require("lib.type.static.v2.defs")

pcall(ffi.cdef, "int memcmp(const void *s1, const void *s2, size_t n);")

local uint8_ptr_t = ffi.typeof("const uint8_t*")

local M = {}

-- FNV-1a 32-bit hash.
-- FNV_PRIME = 16777619 = 2^24 + 403. We split the multiply to stay
-- within double precision: h*2^24 + h*403, then tobit wraps to int32.
local FNV_OFFSET = tobit(0x811c9dc5)

local function fnv1a(ptr, len)
    local h = FNV_OFFSET
    for i = 0, len - 1 do
        h = bxor(h, ptr[i])
        h = tobit(lshift(h, 24) + h * 403)
    end
    return h
end

-- Hash table entries are Lua tables { hash, buf_id, offset, len, id }
-- stored in a sparse Lua table indexed 0..cap-1 (open addressing).
local E_HASH   = 1
local E_BUF    = 2
local E_OFFSET = 3
local E_LEN    = 4
local E_ID     = 5

local function ht_grow(pool)
    local old = pool.entries
    local old_cap = pool.ht_cap
    local new_cap = old_cap * 2
    local new_mask = new_cap - 1
    local new = {}
    for i = 0, old_cap - 1 do
        local e = old[i]
        if e then
            local idx = band(e[E_HASH], new_mask)
            while new[idx] do idx = band(idx + 1, new_mask) end
            new[idx] = e
        end
    end
    pool.entries = new
    pool.ht_cap = new_cap
    pool.ht_mask = new_mask
end

function M.new()
    local cap = 256
    local pool = {
        entries  = {},      -- sparse, indexed 0..cap-1
        ht_cap   = cap,
        ht_mask  = cap - 1,
        ht_count = 0,
        bufs     = {},      -- buf_id → const uint8_t*
        buf_count = 0,
        rev      = {},      -- id → entry table
        next_id  = 0,
        map      = {},      -- keyword string → id (backward compat)
        _anchors = {},      -- prevent GC of source strings
    }

    -- Keyword buffer: concatenate all keywords into one string
    local kw_parts = {}
    for i = 1, #defs.keywords do kw_parts[i] = defs.keywords[i] end
    local kw_str = table.concat(kw_parts)
    pool._anchors[0] = kw_str
    local kw_ptr = ffi.cast(uint8_ptr_t, kw_str)
    pool.bufs[0] = kw_ptr
    pool.buf_count = 1

    -- Pre-intern keywords
    local entries = pool.entries
    local mask = pool.ht_mask
    local pos = 0
    for i = 1, #defs.keywords do
        local kw = defs.keywords[i]
        local len = #kw
        local id = pool.next_id
        local h = fnv1a(kw_ptr + pos, len)
        local idx = band(h, mask)
        while entries[idx] do idx = band(idx + 1, mask) end
        local entry = { h, 0, pos, len, id }
        entries[idx] = entry
        pool.rev[id] = entry
        pool.map[kw] = id
        pool.next_id = id + 1
        pool.ht_count = pool.ht_count + 1
        pos = pos + len
    end

    return pool
end

-- Register a source buffer pointer. Returns buf_id.
-- anchor: optional Lua string to keep alive (prevents GC of the buffer).
function M.register_buf(pool, ptr, anchor)
    local buf_id = pool.buf_count
    pool.bufs[buf_id] = ptr
    if anchor then pool._anchors[buf_id] = anchor end
    pool.buf_count = buf_id + 1
    return buf_id
end

-- Intern from raw pointer (hot path — no Lua string allocation).
-- ptr: const uint8_t* to the bytes
-- len: byte count
-- buf_id, offset: where this string lives (for storage in the entry)
function M.intern_raw(pool, ptr, len, buf_id, offset)
    local h = fnv1a(ptr, len)
    local mask = pool.ht_mask
    local idx = band(h, mask)
    local entries = pool.entries
    local bufs = pool.bufs
    while true do
        local e = entries[idx]
        if e == nil then break end
        if e[E_HASH] == h and e[E_LEN] == len then
            if ffi.C.memcmp(bufs[e[E_BUF]] + e[E_OFFSET], ptr, len) == 0 then
                return e[E_ID]
            end
        end
        idx = band(idx + 1, mask)
    end
    -- Insert
    local id = pool.next_id
    local entry = { h, buf_id, offset, len, id }
    entries[idx] = entry
    pool.rev[id] = entry
    pool.next_id = id + 1
    pool.ht_count = pool.ht_count + 1
    if pool.ht_count * 4 > pool.ht_cap * 3 then ht_grow(pool) end
    return id
end

-- Intern from Lua string (cold path — for escape strings, tests, etc).
function M.intern(pool, s)
    -- Fast path: check Lua map (covers keywords + previously interned strings)
    local map_id = pool.map[s]
    if map_id ~= nil then return map_id end
    -- Probe hash table by raw bytes
    local ptr = ffi.cast(uint8_ptr_t, s)
    local len = #s
    local h = fnv1a(ptr, len)
    local mask = pool.ht_mask
    local idx = band(h, mask)
    local entries = pool.entries
    local bufs = pool.bufs
    while true do
        local e = entries[idx]
        if e == nil then break end
        if e[E_HASH] == h and e[E_LEN] == len then
            if ffi.C.memcmp(bufs[e[E_BUF]] + e[E_OFFSET], ptr, len) == 0 then
                pool.map[s] = e[E_ID]
                return e[E_ID]
            end
        end
        idx = band(idx + 1, mask)
    end
    -- Not found — anchor the Lua string and register as a new buffer
    local anchors = pool._anchors
    anchors[#anchors + 1] = s
    local buf_id = M.register_buf(pool, ptr)
    local id = pool.next_id
    local entry = { h, buf_id, 0, len, id }
    entries[idx] = entry
    pool.rev[id] = entry
    pool.next_id = id + 1
    pool.ht_count = pool.ht_count + 1
    pool.map[s] = id
    if pool.ht_count * 4 > pool.ht_cap * 3 then ht_grow(pool) end
    return id
end

-- Get string by ID (cold path — for diagnostics, error messages, tests).
function M.get(pool, id)
    local e = pool.rev[id]
    if not e then return nil end
    return ffi.string(pool.bufs[e[E_BUF]] + e[E_OFFSET], e[E_LEN])
end

return M
