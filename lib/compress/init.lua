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

local ok, impl = pcall(require, "lib.compress.system")
if not ok then
  impl = require("lib.compress.pure") --[[: any]]
end

return impl --[[: any]]
