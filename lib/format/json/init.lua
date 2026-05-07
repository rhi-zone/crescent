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

--:: JsonEncode = (val: unknown) -> (string | nil, string | nil)
--:: JsonDecode = (s: string) -> (unknown, string | nil)
--:: JsonEncodeRaw = (val: unknown) -> string
--:: JsonDecodeRaw = (s: string) -> unknown
--:: JsonModule = {
--::     null:          {},
--::     encode:        JsonEncode,
--::     decode:        JsonDecode,
--::     _encode_raw:   JsonEncodeRaw,
--::     _decode_raw:   JsonDecodeRaw,
--::     value_to_json: JsonEncodeRaw,
--::     json_to_value: JsonDecodeRaw,
--::     _tier:         string,
--::     _impl:         unknown,
--::     schema:        unknown
--:: }
--: JsonModule
local M = {
    null          = impl.null,
    encode        = impl.encode       --[[:! JsonEncode]],
    decode        = impl.decode       --[[:! JsonDecode]],
    _encode_raw   = impl._encode_raw  --[[:! JsonEncodeRaw]],
    _decode_raw   = impl._decode_raw  --[[:! JsonDecodeRaw]],
    value_to_json = impl._encode_raw  --[[:! JsonEncodeRaw]],
    json_to_value = impl._decode_raw  --[[:! JsonDecodeRaw]],
    _tier         = tier              --[[:! string]],
    _impl         = impl,
    schema        = require("lib.format.json.schema"),
}

return M
