-- lib/format/json/schema.lua
-- Schema-based JSON decoder with pre-interned key strings.
--
-- Faster than json.decode for objects with known field names by pre-interning
-- key strings once at schema creation time, avoiding repeated string allocation
-- on each decode call.
--
-- LIMITATIONS: handles flat objects only (no nested objects/arrays). Values
-- may be strings, numbers (integer or float), booleans (true/false). Nested
-- objects and arrays are not supported — the schema API is explicitly for
-- flat, known-shape records. Use json.decode for arbitrary JSON.
--
-- API:
--   local s = schema({"name", "age", "active"})   -- create schema
--   local obj = s:decode(src)                      -- fresh table each call
--   s:decode_into(src, buf)                        -- populate caller's table
--
-- The pre-interned table PRE maps key string → same key string, so that after
-- extracting a key substring we can look up the interned copy in O(1) rather
-- than re-interning. Unknown keys (not in schema) fall back to src:sub().

local M = {}

-- ── Constructor ───────────────────────────────────────────────────────────────

-- schema(fields) → schema object
-- fields: array of string field names, e.g. {"name", "age", "city"}
local function schema(fields)
    -- Build the pre-interned lookup table: {name="name", age="age", ...}
    local PRE = {}
    for i = 1, #fields do
        local f = fields[i]
        PRE[f] = f
    end

    local self = {}

    -- decode_obj_raw: inner scanner. No pcall — throws on malformed input.
    -- Caller must supply the destination table t.
    --: (src: string, t: { [string]: unknown }) -> { [string]: unknown }
    local function decode_obj_raw(src, t)
        local pos, len = 2, #src
        repeat
            local b = src:byte(pos)
            -- Scan to next opening quote (key start)
            while b ~= 34 and pos <= len do pos = pos + 1; b = src:byte(pos) end
            if b ~= 34 then break end
            -- Consume opening quote; record key start
            pos = pos + 1; local ks = pos; b = src:byte(pos)
            -- Scan to closing quote of key
            while b ~= 34 do pos = pos + 1; b = src:byte(pos) end
            -- Look up pre-interned key or fall back to substring
            local key = PRE[src:sub(ks, pos - 1)] or src:sub(ks, pos - 1)
            -- Skip closing quote + colon (pos+1 is ':', pos+2 is first byte of value)
            pos = pos + 2; b = src:byte(pos)
            if b == 34 then
                -- String value
                pos = pos + 1; local vs = pos; b = src:byte(pos)
                while b ~= 34 do pos = pos + 1; b = src:byte(pos) end
                rawset(t, key, src:sub(vs, pos - 1)); pos = pos + 1
            elseif b == 116 then
                -- true (4 bytes: t-r-u-e)
                rawset(t, key, true); pos = pos + 4
            elseif b == 102 then
                -- false (5 bytes: f-a-l-s-e)
                rawset(t, key, false); pos = pos + 5
            else
                -- Number: scan to comma or closing brace
                local ns = pos; b = src:byte(pos)
                while b ~= 44 and b ~= 125 and pos <= len do
                    pos = pos + 1; b = src:byte(pos)
                end
                rawset(t, key, tonumber(src:sub(ns, pos - 1)))
            end
            -- Consume comma if present
            if src:byte(pos) == 44 then pos = pos + 1 end
        until pos >= len
        return t
    end

    -- decode_into(src, buf): populate buf in-place. Throws on error.
    -- Fast path — no pcall overhead. Caller owns buf and must not retain
    -- a reference across calls if buf is reused.
    function self:decode_into(src, buf)
        return decode_obj_raw(src, buf)
    end

    -- decode(src): decode src into a fresh table. Returns (table) or (nil, err).
    function self:decode(src)
        local t = {}
        local ok, result = pcall(decode_obj_raw, src, t)
        if ok then return result end
        return nil, result
    end

    return self
end

-- The module is the constructor directly, so:
--   local schema = require("lib.format.json.schema")
--   local s = schema({"name", "age"})
return schema
