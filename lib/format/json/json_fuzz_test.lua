-- lib/format/json/json_fuzz_test.lua
-- Parity fuzzing for the JSON library: pure vs ffi tiers.
--
-- Properties tested:
--   1. Decode parity: pure and ffi agree on all inputs (both error or both
--      succeed with deeply-equal results).
--   2. Round-trip: encode(decode(s)) produces a value that round-trips again
--      (second decode equals first decode).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local arb  = require("lib.test.arb")
local fuzz = require("lib.test.fuzz")
local json = require("lib.format.json")
local pure = require("lib.format.json.pure")
local ffi_impl = require("lib.format.json.ffi")

-- Use json.null as the shared sentinel for cross-tier comparisons.
local NULL = json.null

-- ── Deep equality ─────────────────────────────────────────────────────────────

local function deep_eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table"  then return a == b end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- ── Generators ────────────────────────────────────────────────────────────────

-- Generate a valid JSON string (we start from known-good fragments and mutate).
-- The corpus covers representative JSON forms.
local JSON_CORPUS = {
    "null",
    "true",
    "false",
    "0",
    "42",
    "-1",
    "3.14",
    "1e10",
    "-0",
    '""',
    '"hello"',
    '"a\\nb"',
    '"\\u0041"',
    '"\\uD83D\\uDE00"',
    "[]",
    "[1,2,3]",
    "{}",
    '{"a":1}',
    '{"x":true,"y":null}',
    "[1,[2,[3]]]",
    '{"a":{"b":{"c":42}}}',
    "[null,true,false,0,\"s\"]",
}

-- Generator: arbitrary JSON value as a Lua value (for encode-side testing).
-- Uses arb for integrated shrinking.

local arb_null     = arb.constant(NULL)
local arb_bool     = arb.one_of({ arb.constant(true), arb.constant(false) })
local arb_int      = arb.int(-1000, 1000)
local arb_float    = arb.map(arb_int, function(n) return n * 0.1 end)
local arb_number   = arb.one_of({ arb_int, arb_float })
local arb_strchars = arb.map(arb.array(arb.int(0x20, 0x7E), {min=0, max=20}), function(t)
    local chars = {}
    for i = 1, #t do
        -- Exclude " (0x22) and \ (0x5C) from random strings to keep them valid.
        local b = t[i]
        if b ~= 0x22 and b ~= 0x5C then chars[#chars + 1] = string.char(b) end
    end
    return table.concat(chars)
end)

-- We define a JSON value generator that doesn't recurse deeply (arb.sized
-- handles depth limiting).
local function make_arb_json_value(depth)
    if depth <= 0 then
        -- Leaf: null, bool, number, or simple string.
        return arb.one_of({ arb_null, arb_bool, arb_number, arb_strchars })
    end
    -- Non-leaf: can also be array or object.
    local leaf = arb.one_of({ arb_null, arb_bool, arb_number, arb_strchars })
    local elem = make_arb_json_value(depth - 1)
    local arr = arb.map(arb.array(elem, {min=0, max=5}), function(t) return t end)
    -- Objects: array of {key, val} pairs → build table.
    local pair_gen = arb.tuple({ arb_strchars, elem })
    local obj = arb.map(arb.array(pair_gen, {min=0, max=5}), function(pairs)
        local t = {}
        for _, p in ipairs(pairs) do
            local k, v = p[1], p[2]
            if k ~= "" then t[k] = v end  -- skip empty keys to avoid degenerate objects
        end
        return t
    end)
    return arb.one_of({ leaf, arr, obj })
end

local arb_json_value = make_arb_json_value(3)

-- ── Property 1: decode parity via fuzz ────────────────────────────────────────
-- Mutate arbitrary byte strings: pure and ffi must agree (both error or both
-- succeed with deep-equal results).

T.describe("json fuzz: decode parity (pure == ffi on arbitrary input)", function()
    T.it("decode parity over 2000 mutations", function()
        local result = fuzz.run(function(input)
            local ok1, v1 = pcall(pure._decode_raw, input, NULL)
            local ok2, v2 = pcall(ffi_impl._decode_raw, input, NULL)
            if ok1 ~= ok2 then
                error("tier disagreement: pure=" .. tostring(ok1) .. " ffi=" .. tostring(ok2)
                    .. " input=" .. string.format("%q", input))
            end
            if ok1 and not deep_eq(v1, v2) then
                error("tier result mismatch on: " .. string.format("%q", input))
            end
        end, {
            seeds = JSON_CORPUS,
            iters = 2000,
            mode  = "fast",
            -- Both tiers may legitimately error on malformed input.
            -- We only care that they agree.
            expected_errs = {
                "unexpected token",
                "unterminated",
                "invalid",
                "unpaired",
                "truncated",
                "nesting depth",
                "trailing garbage",
                "expected",
                "end of input",
            },
        })
        T.ok(#result.crashes == 0,
            "no parity crashes in " .. result.iters .. " iterations")
    end)
end)

-- ── Property 2: round-trip via arb ────────────────────────────────────────────
-- For any generated JSON value: encode then decode gives back an equal value.

T.describe("json arb: encode/decode round-trip", function()
    arb.it("pure: encode→decode round-trip", arb_json_value, function(v)
        local s  = pure._encode_raw(v, NULL)
        local v2 = pure._decode_raw(s, NULL)
        if not deep_eq(v, v2) then
            error("round-trip failed: input=" .. tostring(v)
                .. " encoded=" .. s .. " decoded=" .. tostring(v2))
        end
    end, { trials = 500 })

    arb.it("ffi: encode→decode round-trip", arb_json_value, function(v)
        local s  = ffi_impl._encode_raw(v, NULL)
        local v2 = ffi_impl._decode_raw(s, NULL)
        if not deep_eq(v, v2) then
            error("round-trip failed: input=" .. tostring(v)
                .. " encoded=" .. s .. " decoded=" .. tostring(v2))
        end
    end, { trials = 500 })

    arb.it("cross-tier: pure.encode → ffi.decode round-trip", arb_json_value, function(v)
        local s  = pure._encode_raw(v, NULL)
        local v2 = ffi_impl._decode_raw(s, NULL)
        if not deep_eq(v, v2) then
            error("cross-tier round-trip failed")
        end
    end, { trials = 500 })

    arb.it("cross-tier: ffi.encode → pure.decode round-trip", arb_json_value, function(v)
        local s  = ffi_impl._encode_raw(v, NULL)
        local v2 = pure._decode_raw(s, NULL)
        if not deep_eq(v, v2) then
            error("cross-tier round-trip failed")
        end
    end, { trials = 500 })
end)

-- ── Property 3: encode parity via arb ─────────────────────────────────────────
-- pure.encode and ffi.encode must produce identical byte-for-byte output.

T.describe("json arb: encode parity (pure == ffi)", function()
    arb.it("encode byte-for-byte identical", arb_json_value, function(v)
        local ps = pure._encode_raw(v, NULL)
        local fs = ffi_impl._encode_raw(v, NULL)
        if ps ~= fs then
            error("encode mismatch: pure=" .. ps .. " ffi=" .. fs)
        end
    end, { trials = 500 })
end)
