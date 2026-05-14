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

-- ── Public module ──────────────────────────────────────────────────────────────

--:: Base64Encode = (str: string, opts: { url: boolean | nil, pad: boolean | nil } | nil) -> string
--:: Base64Decode = (b64: string, opts: { url: boolean | nil } | nil) -> (string | nil, string | nil)
--:: Base64Impl = {
--::     encode: Base64Encode,
--::     decode: Base64Decode,
--:: }
--:: Base64Module = {
--::     encode: Base64Encode,
--::     decode: Base64Decode,
--::     _tier:  string,
--::     _impl:  Base64Impl,
--:: }

-- ── Tier selection ─────────────────────────────────────────────────────────────
-- Pure-Lua tier is the baseline (always available, statically typed). Optional
-- tiers (ffi/simd) come back through `pcall(require, ...)` which loses the
-- module's static type; we runtime-narrow and cast at the pcall boundary.

local impl = require("lib.encode.base64.pure") --: Base64Impl
local tier = "pure" --: string

-- Try Tier 2: FFI scalar.
local ok2, ffi_impl_raw = pcall(require, "lib.encode.base64.ffi")
local ffi_impl = ffi_impl_raw --[[: unknown]]
if ok2 and type(ffi_impl) == "table" and (ffi_impl --[[: { encode: unknown, ... }]]).encode then
    impl = ffi_impl --[[:! Base64Impl]]
    tier = "ffi"
end

-- Try Tier 3: SIMD (stub — always returns false).
local ok3, simd_result_raw = pcall(require, "lib.encode.base64.simd")
local simd_result = simd_result_raw --[[: unknown]]
if ok3 and type(simd_result) == "table" and (simd_result --[[: { encode: unknown, ... }]]).encode then
    impl = simd_result --[[:! Base64Impl]]
    tier = "simd"
end

--: Base64Module
local M = {
    encode = impl.encode,
    decode = impl.decode,
    _tier  = tier,
    _impl  = impl,
}

return M
