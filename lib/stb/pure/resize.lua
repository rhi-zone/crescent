-- lib/stb/pure/resize.lua
-- Nearest-neighbor image resize. Full implementation.
--
-- API:
--   resize_nn(pixels, src_w, src_h, dst_w, dst_h, channels) -> string  OR  nil, errmsg
--
-- pixels:  raw byte string, row-major, `channels` bytes per pixel
-- returns: raw byte string of same format, dst_w * dst_h * channels bytes
--
-- Uses an FFI buffer for output on LuaJIT to avoid large table-of-strings allocations.
-- Falls back to pure-Lua table.concat on PUC-Rio Lua.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Detect FFI availability (LuaJIT). Fall back to pure table concat on PUC-Rio.
local ffi_ok, ffi = pcall(require, "ffi")

if ffi_ok then
  --: (pixels: string, src_w: integer, src_h: integer, dst_w: integer, dst_h: integer, channels: integer) -> (string | nil, string | nil)
  function M.resize_nn(pixels, src_w, src_h, dst_w, dst_h, channels)
    if src_w <= 0 or src_h <= 0 or dst_w <= 0 or dst_h <= 0 or channels <= 0 then
      return nil, "invalid dimensions"
    end
    local nbytes = dst_w * dst_h * channels
    local dst = ffi.new("uint8_t[?]", nbytes)

    local di = 0  -- destination index (0-based into dst)
    for dy = 0, dst_h - 1 do
      -- Map destination row to source row via nearest-neighbor.
      local sy = math.floor(dy * src_h / dst_h)
      local src_row_base = sy * src_w  -- pixel index of first pixel in src row
      for dx = 0, dst_w - 1 do
        local sx = math.floor(dx * src_w / dst_w)
        -- Source byte offset (1-indexed for string.byte).
        local src_off = (src_row_base + sx) * channels + 1
        for c = 0, channels - 1 do
          dst[di + c] = string.byte(pixels, src_off + c)
        end
        di = di + channels
      end
    end

    return ffi.string(dst, nbytes)
  end
else
  -- Pure-Lua fallback: build output as table of single-char strings.
  --: (pixels: string, src_w: integer, src_h: integer, dst_w: integer, dst_h: integer, channels: integer) -> (string | nil, string | nil)
  function M.resize_nn(pixels, src_w, src_h, dst_w, dst_h, channels)
    if src_w <= 0 or src_h <= 0 or dst_w <= 0 or dst_h <= 0 or channels <= 0 then
      return nil, "invalid dimensions"
    end
    local out = {}
    local di = 1

    for dy = 0, dst_h - 1 do
      local sy = math.floor(dy * src_h / dst_h)
      local src_row_base = sy * src_w
      for dx = 0, dst_w - 1 do
        local sx = math.floor(dx * src_w / dst_w)
        local src_off = (src_row_base + sx) * channels + 1
        for c = 0, channels - 1 do
          out[di] = string.char(string.byte(pixels, src_off + c))
          di = di + 1
        end
      end
    end

    return table.concat(out)
  end
end

return M
