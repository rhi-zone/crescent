-- lib/format/json/init.lua
-- Crescent JSON library — three-tier implementation.
--
-- Tier selection (best available at load time):
--   simd  — libcrescentjson (simdjson C shim); requires pre-built .so/.dylib
--   ffi   — LuaJIT FFI scalar; requires LuaJIT
--   pure  — pure Lua; works on PUC-Rio Lua 5.2+ and LuaJIT
--
-- Public API:
--   json.encode(value)       → string | (nil, errmsg)
--   json.decode(str)         → value  | (nil, errmsg)
--   json.null                — sentinel for JSON null
--   json.value_to_json       — alias for the raw encoder (throws on error)
--   json.json_to_value       — alias for the raw decoder (throws on error)
--   json._encode_raw         — alias for the raw encoder (throws on error)
--   json._decode_raw         — alias for the raw decoder (throws on error)
--   json._tier               — "simd" | "ffi" | "pure"
--   json._impl               — the selected implementation table

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

-- ── Tier selection ────────────────────────────────────────────────────────────

local impl, tier

-- Try Tier 3: simdjson via C shim.
-- simd.lua returns a table (impl) if available, or false/nil if not.
local ok3, simd_result = pcall(require, "lib.format.json.simd")
if ok3 and type(simd_result) == "table" and simd_result.encode then
    impl = simd_result
    tier = "simd"
end

-- Try Tier 2: FFI scalar.
if not impl then
    local ok2, ffi_impl = pcall(require, "lib.format.json.ffi")
    if ok2 and ffi_impl and ffi_impl.encode then
        impl = ffi_impl
        tier = "ffi"
    end
end

-- Tier 1: pure Lua (always available).
if not impl then
    impl = require("lib.format.json.pure")
    tier = "pure"
end

-- ── Public module ─────────────────────────────────────────────────────────────

local M = {}

M.null         = impl.null
M.encode       = impl.encode
M.decode       = impl.decode
M._encode_raw  = impl._encode_raw
M._decode_raw  = impl._decode_raw
M.value_to_json = impl._encode_raw
M.json_to_value = impl._decode_raw
M._tier        = tier
M._impl        = impl
M.schema       = require("lib.format.json.schema")

--:: module "lib.format.json": { encode: (unknown) -> (string | nil, string | nil), decode: (string) -> (unknown, string | nil), null: {}, _tier: string, _encode_raw: (unknown) -> string, _decode_raw: (string) -> unknown, value_to_json: (unknown) -> string, json_to_value: (string) -> unknown, schema: unknown }

return M
