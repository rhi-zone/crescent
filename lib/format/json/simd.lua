-- lib/format/json/simd.lua
-- Tier 3: simdjson bindings via a thin C shim.
-- If the pre-built shared library is not present, returns nil (caller falls through).
--
-- simdjson is a C++ library; a thin C shim (libcrescentjson) exposes a C API.
-- Since crescent has no build step, this tier loads a pre-built shared library
-- (libcrescentjson.so / libcrescentjson.dylib) via ffi.load. If not found,
-- this module returns nil and the tier selection falls back to Tier 2 (ffi).
--
-- TODO: implement simdjson C shim and binding when build infrastructure exists.
--       The shim should expose:
--
--   typedef struct simdjson_parser simdjson_parser;
--   simdjson_parser* simdjson_new(size_t capacity);
--   void             simdjson_free(simdjson_parser* p);
--   int              simdjson_parse(simdjson_parser* p,
--                                   const char* json, size_t len,
--                                   char** result_json_out, size_t* result_len);
--   void             simdjson_result_free(char* s);
--
--   Where simdjson_parse re-serialises the parsed value as canonical JSON so
--   the Lua layer can decode it with the Tier 2 decoder.  A more efficient
--   design would walk the tape directly from Lua, but that requires a richer
--   API and is deferred.

-- Try to load the pre-built shim library.
local ok, ffi = pcall(require, "ffi")
if not ok then return nil end

-- Probe for the shared library under known names.
local lib
local names = { "crescentjson", "libcrescentjson.so", "libcrescentjson.dylib" }
for _, name in ipairs(names) do
    local ok2, l = pcall(ffi.load, name)
    if ok2 then lib = l; break end
end

if not lib then
    -- Library not available — fall through to Tier 2.
    return false
end

-- If we reach here, the library loaded.  The actual binding is a stub until
-- the C shim is built; return false so the caller falls back to Tier 2.
-- TODO: implement the real binding once the shim exists.
return false
