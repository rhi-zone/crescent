-- lib/compress/init.lua
-- Tiered zlib/gzip compression: system zlib FFI > pure Lua inflate.
-- Tier selected at load time via pcall; best available wins.
--
-- Public API:
--   M.deflate(input, opts)   -> compressed, err
--   M.inflate(input, opts)   -> decompressed, err
--   M.encode = M.deflate     (codec alias)
--   M.decode = M.inflate     (codec alias)
--   M.deflater(opts)         -> {push, finish}
--   M.inflater(opts)         -> {push, finish}
--   M._tier                  -> "system-zlib" | "pure-lua"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local ok, impl_raw = pcall(require, "lib.compress.system")
local impl --: unknown
if ok then
  impl = impl_raw
else
  impl = require("lib.compress.pure")
end
local impl_t = impl --[[:! { encode: unknown, decode: unknown, deflate: unknown, inflate: unknown, deflater: unknown, inflater: unknown, _tier: unknown, ... }]]

--:: Deflate = (input: string, opts: { level: number | nil, format: string | nil } | nil) -> (string | nil, string | nil)
--:: Inflate = (input: string, opts: { format: string | nil } | nil) -> (string | nil, string | nil)
--:: Deflater = (opts: { level: number | nil, format: string | nil } | nil) -> unknown
--:: Inflater = (opts: { format: string | nil } | nil) -> unknown
--:: CompressModule = {
--::     deflate:  Deflate,
--::     inflate:  Inflate,
--::     encode:   Deflate,
--::     decode:   Inflate,
--::     deflater: Deflater,
--::     inflater: Inflater,
--::     _tier:    string,
--:: }
--: CompressModule
local M = {
  deflate  = impl_t.deflate  --[[:! Deflate]],
  inflate  = impl_t.inflate  --[[:! Inflate]],
  encode   = impl_t.encode   --[[:! Deflate]],
  decode   = impl_t.decode   --[[:! Inflate]],
  deflater = impl_t.deflater --[[:! Deflater]],
  inflater = impl_t.inflater --[[:! Inflater]],
  _tier    = impl_t._tier    --[[:! string]],
}

return M
