-- lib/encode/base64/simd.lua
-- Tier 3 stub: SIMD-accelerated base64 via a pre-built shared library.
-- Returns false — no library available yet; caller falls back to Tier 2 (ffi).
--
-- TODO: implement SIMD bindings (e.g. base64-avx2 via C shim) when build
--       infrastructure exists. The shim should expose:
--
--   size_t crescent_base64_encode(const uint8_t *src, size_t srclen,
--                                  char *dst, int url_safe, int padding);
--   ssize_t crescent_base64_decode(const char *src, size_t srclen,
--                                   uint8_t *dst, int url_safe);

return false
