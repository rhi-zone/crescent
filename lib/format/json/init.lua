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

-- ── Public module ─────────────────────────────────────────────────────────────

-- ── Public module ─────────────────────────────────────────────────────────────

--:: JsonEncode = (val: unknown, null_sentinel: unknown) -> (string | nil, string | nil)
--:: JsonDecode = (s: string, null_sentinel: unknown) -> (unknown, string | nil)
--:: JsonEncodeRaw = (val: unknown, null_sentinel: unknown) -> string
--:: JsonDecodeRaw = (s: string, null_sentinel: unknown) -> unknown
--:: JsonImpl = {
--::     null:          {},
--::     encode:        JsonEncode,
--::     decode:        JsonDecode,
--::     _encode_raw:   JsonEncodeRaw,
--::     _decode_raw:   JsonDecodeRaw,
--::     value_to_json: JsonEncodeRaw,
--::     json_to_value: JsonDecodeRaw,
--:: }
--:: JsonModule = {
--::     null:          {},
--::     encode:        JsonEncode,
--::     decode:        JsonDecode,
--::     _encode_raw:   JsonEncodeRaw,
--::     _decode_raw:   JsonDecodeRaw,
--::     value_to_json: JsonEncodeRaw,
--::     json_to_value: JsonDecodeRaw,
--::     _tier:         string,
--::     _impl:         JsonImpl,
--::     schema:        unknown
--:: }

-- ── Tier selection ────────────────────────────────────────────────────────────
-- The pure-Lua tier is the baseline (always available, statically typed and
-- imported directly). Optional tiers (simd/ffi) come back through
-- `pcall(require, ...)`, which loses the module's static type; we narrow at
-- runtime and treat the result as a JsonImpl. The pcall boundary is the one
-- legitimate cast site — every consumer downstream sees the typed JsonImpl.

local impl = require("lib.format.json.pure") --: JsonImpl
local tier = "pure" --: string

-- Try Tier 2: FFI scalar.
local ok2, ffi_impl_raw = pcall(require, "lib.format.json.ffi")
local ffi_impl = ffi_impl_raw --[[: unknown]]
if ok2 and type(ffi_impl) == "table" and (ffi_impl --[[: { encode: unknown, ... }]]).encode then
    impl = ffi_impl --[[:! JsonImpl]]
    tier = "ffi"
end

-- Try Tier 3: simdjson via C shim.
local ok3, simd_result_raw = pcall(require, "lib.format.json.simd")
local simd_result = simd_result_raw --[[: unknown]]
if ok3 and type(simd_result) == "table" and (simd_result --[[: { encode: unknown, ... }]]).encode then
    impl = simd_result --[[:! JsonImpl]]
    tier = "simd"
end

--: JsonModule
local M = {
    null          = impl.null,
    encode        = impl.encode,
    decode        = impl.decode,
    _encode_raw   = impl._encode_raw,
    _decode_raw   = impl._decode_raw,
    value_to_json = impl._encode_raw,
    json_to_value = impl._decode_raw,
    _tier         = tier,
    _impl         = impl,
    schema        = require("lib.format.json.schema"),
}

return M
