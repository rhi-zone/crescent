-- lib/encode/base64/init.lua
-- Base64 encoding and decoding (RFC 4648 §4 standard, §5 URL-safe).
-- Three-tier implementation; best available selected at load time.
--
-- Tier selection:
--   simd  — SIMD via pre-built shared library (stub; always falls through)
--   ffi   — LuaJIT FFI scalar (zero-copy byte access via uint8_t*)
--   pure  — pure Lua (works on PUC-Rio Lua 5.2+ and LuaJIT)
--
-- Public API:
--   M.encode(str, opts)   → string
--   M.decode(b64, opts)   → string | (nil, errmsg)
--   M._tier               → "ffi" | "pure"
--   M._impl               → the selected implementation table

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

-- ── Tier selection ─────────────────────────────────────────────────────────────

local impl, tier

-- Try Tier 3: SIMD (stub — always returns false).
local ok3, simd_result = pcall(require, "lib.encode.base64.simd")
if ok3 and type(simd_result) == "table" and simd_result.encode then
    impl = simd_result
    tier = "simd"
end

-- Try Tier 2: FFI scalar.
if not impl then
    local ok2, ffi_impl = pcall(require, "lib.encode.base64.ffi")
    if ok2 and ffi_impl and ffi_impl.encode then
        impl = ffi_impl
        tier = "ffi"
    end
end

-- Tier 1: pure Lua (always available).
if not impl then
    impl = require("lib.encode.base64.pure")
    tier = "pure"
end

-- ── Public module ──────────────────────────────────────────────────────────────

--:: Base64Encode = (str: string, opts: { url: boolean | nil, pad: boolean | nil } | nil) -> string
--:: Base64Decode = (b64: string, opts: { url: boolean | nil } | nil) -> (string | nil, string | nil)
--:: Base64Module = {
--::     encode: Base64Encode,
--::     decode: Base64Decode,
--::     _tier:  string,
--::     _impl:  unknown,
--:: }
--: Base64Module
local M = {
    encode = impl.encode --[[:! Base64Encode]],
    decode = impl.decode --[[:! Base64Decode]],
    _tier  = tier        --[[:! string]],
    _impl  = impl,
}

return M
