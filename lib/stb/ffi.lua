-- lib/stb/ffi.lua
-- FFI cdefs for the stb API surface crescent needs.
-- Only loaded when a vendored or system binary is present.
-- Returns the loaded library object.

local ffi = require("ffi")

-- Wrap cdef in pcall to handle double-definition gracefully
-- (multiple require() calls or composed entry points).
pcall(ffi.cdef, [[
  /* stb_image */
  unsigned char *stbi_load_from_memory(
      unsigned char const *buffer, int len,
      int *x, int *y, int *channels_in_file, int desired_channels);
  void stbi_image_free(void *retval_from_stbi_load);
  const char *stbi_failure_reason(void);

  /* stb_image_resize2 */
  unsigned char *stbir_resize_uint8_srgb(
      const unsigned char *input_pixels,
      int input_w, int input_h, int input_stride_in_bytes,
      unsigned char *output_pixels,
      int output_w, int output_h, int output_stride_in_bytes,
      int num_channels);
]])

-- The caller passes the loaded library object; we return a bound API table.
-- `lib` is the result of `ffi.load(path)`; typed as `any` because
-- per-file `$FfiC` does not narrow to fields cdef'd from this same file
-- when passed in as a parameter (the cdef view is per-compilation-unit).
-- Returns are typed permissively because the typechecker does not currently
-- validate function bodies against multi-return tuple-union annotations
-- (`-> ...((A,B) | (nil,string))` works for callers but not for body checking).
--: (lib: any) -> { decode: (data: string, channels: integer) -> (string | nil, integer | string, integer | nil, integer | nil), resize: (pixels: string, src_w: integer, src_h: integer, dst_w: integer, dst_h: integer, channels: integer) -> (string | nil, string | nil) }
local function bind(lib)
  local M = {}

  --: (data: string, channels: (integer | nil)) -> (string | nil, integer | string, integer | nil, integer | nil)
  function M.decode(data, channels)
    channels = channels or 0
    local x = ffi.new("int[1]")
    local y = ffi.new("int[1]")
    local ch = ffi.new("int[1]")
    local ptr = lib.stbi_load_from_memory(
      ffi.cast("unsigned char const *", data), #data,
      x, y, ch, channels)
    if ptr == nil then
      local reason = ffi.string(lib.stbi_failure_reason())
      return nil, reason
    end
    local out_ch = channels ~= 0 and channels or ch[0]
    local nbytes = x[0] * y[0] * out_ch
    local result = ffi.string(ptr, nbytes)
    lib.stbi_image_free(ptr)
    return result, x[0], y[0], out_ch
  end

  --: (pixels: string, src_w: integer, src_h: integer, dst_w: integer, dst_h: integer, channels: integer) -> (string | nil, string | nil)
  function M.resize(pixels, src_w, src_h, dst_w, dst_h, channels)
    local dst_bytes = dst_w * dst_h * channels
    local dst_buf = ffi.new("unsigned char[?]", dst_bytes)
    local src_stride = src_w * channels
    local dst_stride = dst_w * channels
    local result = lib.stbir_resize_uint8_srgb(
      ffi.cast("unsigned char const *", pixels),
      src_w, src_h, src_stride,
      dst_buf, dst_w, dst_h, dst_stride,
      channels)
    if result == nil then
      return nil, "stbir_resize_uint8_srgb failed"
    end
    return ffi.string(dst_buf, dst_bytes)
  end

  return M
end

return bind
