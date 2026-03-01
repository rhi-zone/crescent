-- lib/type/static/v2/intern.lua
-- String interning: string → int32, int32 → string.
-- IDs start at 0 to align with FFI array indexing.
-- Keywords are pre-interned so keyword lookup is pool.map[word].

local defs = require("lib.type.static.v2.defs")

local M = {}

function M.new()
    local pool = { map = {}, strs = {}, next_id = 0 }
    -- Pre-intern keywords at IDs 0..NUM_KEYWORDS-1
    for i = 1, #defs.keywords do
        local kw = defs.keywords[i]
        local id = pool.next_id
        pool.map[kw] = id
        pool.strs[id] = kw
        pool.next_id = id + 1
    end
    return pool
end

function M.intern(pool, s)
    local id = pool.map[s]
    if id then return id end
    id = pool.next_id
    pool.map[s] = id
    pool.strs[id] = s
    pool.next_id = id + 1
    return id
end

function M.get(pool, id)
    return pool.strs[id]
end

return M
