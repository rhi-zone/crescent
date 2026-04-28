-- lib/compress/system.lua
-- Tier 1: zlib compression via FFI bindings to system libz.
-- Wraps compress2/uncompress for one-shot and deflateInit2_/inflateInit2_ for streaming.

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
  const char *zlibVersion(void);

  typedef unsigned long uLong;
  typedef unsigned int uInt;
  typedef unsigned char Byte;
  typedef Byte *Bytef;
  typedef void *voidpf;
  typedef uLong uLongf;

  typedef struct z_stream_s {
    const Bytef *next_in;
    uInt avail_in;
    uLong total_in;
    Bytef *next_out;
    uInt avail_out;
    uLong total_out;
    const char *msg;
    void *state;
    voidpf zalloc;
    voidpf zfree;
    voidpf opaque;
    int data_type;
    uLong adler;
    uLong reserved;
  } z_stream;

  int compress2(Bytef *dest, uLongf *destLen,
                const Bytef *source, uLong sourceLen, int level);
  int uncompress(Bytef *dest, uLongf *destLen,
                 const Bytef *source, uLong sourceLen);

  int deflateInit2_(z_stream *strm, int level, int method,
                    int windowBits, int memLevel, int strategy,
                    const char *version, int stream_size);
  int deflate(z_stream *strm, int flush);
  int deflateEnd(z_stream *strm);

  int inflateInit2_(z_stream *strm, int windowBits,
                    const char *version, int stream_size);
  int inflate(z_stream *strm, int flush);
  int inflateEnd(z_stream *strm);
]]

-- Try vendored path first, then known system library names.
--: () -> string | nil
local function vendored_name()
  local os, arch = ffi.os, ffi.arch
  if os == "Linux" then
    return arch == "arm64" and "dep/libz-linux-aarch64.so"
                           or  "dep/libz-linux-x86_64.so"
  elseif os == "OSX" then
    return arch == "arm64" and "dep/libz-macos-arm64.dylib" or nil
  elseif os == "Windows" then
    return arch == "x86" and "dep/zlib-x86.dll" or "dep/zlib.dll"
  end
  return nil
end

local names = {} --: { [integer]: string }
local v = vendored_name()
if v then names[#names + 1] = v end
for _, name in ipairs({ "z", "zlib", "zlib1", "libz" }) do
  names[#names + 1] = name
end

--:: ZlibLib = {
--::   zlibVersion: () -> string,
--::   deflateInit2_: (unknown, number, number, number, number, number, string, integer) -> integer,
--::   deflate: (unknown, number) -> integer,
--::   deflateEnd: (unknown) -> integer,
--::   inflateInit2_: (unknown, number, string, integer) -> integer,
--::   inflate: (unknown, number) -> integer,
--::   inflateEnd: (unknown) -> integer,
--:: }
local function load_zlib() --: () -> ZlibLib, string
  for _, name in ipairs(names) do
    local ok, lib = pcall(ffi.load, name)
    if ok then
      local lib_typed = lib --: ZlibLib
      return lib_typed, name
    end
  end
  error("zlib not found")
end
local zlib, zlib_loaded_from = load_zlib()

local Z_OK            = 0
local Z_STREAM_END    = 1
local Z_FINISH        = 4
local Z_NO_FLUSH      = 0
local Z_DEFLATED      = 8
local Z_DEFAULT_STRATEGY = 0

local CHUNK = 65536

local z_version = zlib.zlibVersion()
local z_stream_size = ffi.sizeof("z_stream")

--: (string) -> number
local function window_bits_deflate(format)
  if format == "raw" then return -15 end
  if format == "gzip" then return 15 + 16 end
  return 15 -- zlib (default)
end

--: (string) -> number
local function window_bits_inflate(format)
  if format == "raw" then return -15 end
  if format == "gzip" then return 15 + 16 end
  -- zlib default, but also auto-detect gzip
  return 15 + 32
end

local dest_len_buf = ffi.new("uLongf[1]")

-- ── One-shot deflate ─────────────────────────────────────────────────────────

--: (string, { level: number | nil, format: string | nil } | nil) -> string | nil, string | nil
local function deflate(input, opts)
  local level --: number
  local format --: string
  if opts then
    level = opts.level or 6
    format = opts.format or "zlib"
  else
    level = 6
    format = "zlib"
  end

  local src = ffi.cast("const Bytef *", input)
  local src_len = #input

  -- Use streaming API for format support (compress2 only does zlib)
  local strm = ffi.new("z_stream")
  local wb = window_bits_deflate(format)
  local ret = zlib.deflateInit2_(strm, level, Z_DEFLATED, wb, 8,
                                  Z_DEFAULT_STRATEGY, z_version, z_stream_size)
  if ret ~= Z_OK then
    return nil, "deflateInit2 failed: " .. ret
  end

  strm.next_in = src
  strm.avail_in = src_len

  local chunks = {}
  local buf = ffi.new("Byte[?]", CHUNK)

  repeat
    strm.next_out = ffi.cast("Bytef *", buf)
    strm.avail_out = CHUNK
    ret = zlib.deflate(strm, Z_FINISH)
    if ret ~= Z_OK and ret ~= Z_STREAM_END then
      zlib.deflateEnd(strm)
      return nil, "deflate failed: " .. ret
    end
    local have = CHUNK - strm.avail_out
    if have > 0 then
      chunks[#chunks + 1] = ffi.string(buf, have)
    end
  until ret == Z_STREAM_END

  zlib.deflateEnd(strm)
  return table.concat(chunks)
end

-- ── One-shot inflate ─────────────────────────────────────────────────────────

--: (string, { format: string | nil } | nil) -> string | nil, string | nil
local function inflate(input, opts)
  local format --: string
  if opts then format = opts.format or "zlib" else format = "zlib" end

  local src = ffi.cast("const Bytef *", input)
  local src_len = #input

  local strm = ffi.new("z_stream")
  local wb = window_bits_inflate(format)
  local ret = zlib.inflateInit2_(strm, wb, z_version, z_stream_size)
  if ret ~= Z_OK then
    return nil, "inflateInit2 failed: " .. ret
  end

  strm.next_in = src
  strm.avail_in = src_len

  local chunks = {}
  local buf = ffi.new("Byte[?]", CHUNK)

  repeat
    strm.next_out = ffi.cast("Bytef *", buf)
    strm.avail_out = CHUNK
    ret = zlib.inflate(strm, Z_NO_FLUSH)
    if ret ~= Z_OK and ret ~= Z_STREAM_END then
      zlib.inflateEnd(strm)
      local msg = strm.msg ~= nil and ffi.string(strm.msg) or ("code " .. ret)
      return nil, "inflate failed: " .. msg
    end
    local have = CHUNK - strm.avail_out
    if have > 0 then
      chunks[#chunks + 1] = ffi.string(buf, have)
    end
  until ret == Z_STREAM_END

  zlib.inflateEnd(strm)
  return table.concat(chunks)
end

-- ── Streaming deflater ───────────────────────────────────────────────────────

--: ({ level: number | nil, format: string | nil } | nil) -> unknown
local function deflater(opts)
  local level --: number
  local format --: string
  if opts then
    level = opts.level or 6
    format = opts.format or "zlib"
  else
    level = 6
    format = "zlib"
  end

  local strm = ffi.new("z_stream")
  local wb = window_bits_deflate(format)
  local ret = zlib.deflateInit2_(strm, level, Z_DEFLATED, wb, 8,
                                  Z_DEFAULT_STRATEGY, z_version, z_stream_size)
  if ret ~= Z_OK then
    return nil, "deflateInit2 failed: " .. ret
  end

  local chunks = {}
  local buf = ffi.new("Byte[?]", CHUNK)
  local finished = false

  return {
    --: (string) -> boolean | nil, string | nil
    push = function(chunk)
      if finished then return nil, "deflater already finished" end
      local src = ffi.cast("const Bytef *", chunk)
      strm.next_in = src
      strm.avail_in = #chunk
      repeat
        strm.next_out = ffi.cast("Bytef *", buf)
        strm.avail_out = CHUNK
        ret = zlib.deflate(strm, Z_NO_FLUSH)
        if ret ~= Z_OK then
          zlib.deflateEnd(strm)
          return nil, "deflate failed: " .. ret
        end
        local have = CHUNK - strm.avail_out
        if have > 0 then
          chunks[#chunks + 1] = ffi.string(buf, have)
        end
      until strm.avail_out ~= 0
      return true
    end,
    --: () -> string | nil, string | nil
    finish = function()
      if finished then return nil, "deflater already finished" end
      finished = true
      strm.next_in = nil
      strm.avail_in = 0
      repeat
        strm.next_out = ffi.cast("Bytef *", buf)
        strm.avail_out = CHUNK
        ret = zlib.deflate(strm, Z_FINISH)
        if ret ~= Z_OK and ret ~= Z_STREAM_END then
          zlib.deflateEnd(strm)
          return nil, "deflate finish failed: " .. ret
        end
        local have = CHUNK - strm.avail_out
        if have > 0 then
          chunks[#chunks + 1] = ffi.string(buf, have)
        end
      until ret == Z_STREAM_END
      zlib.deflateEnd(strm)
      return table.concat(chunks)
    end,
  }
end

-- ── Streaming inflater ───────────────────────────────────────────────────────

--: ({ format: string | nil } | nil) -> unknown
local function inflater(opts)
  local format --: string
  if opts then format = opts.format or "zlib" else format = "zlib" end

  local strm = ffi.new("z_stream")
  local wb = window_bits_inflate(format)
  local ret = zlib.inflateInit2_(strm, wb, z_version, z_stream_size)
  if ret ~= Z_OK then
    return nil, "inflateInit2 failed: " .. ret
  end

  local chunks = {}
  local buf = ffi.new("Byte[?]", CHUNK)
  local finished = false

  return {
    --: (string) -> boolean | nil, string | nil
    push = function(chunk)
      if finished then return nil, "inflater already finished" end
      local src = ffi.cast("const Bytef *", chunk)
      strm.next_in = src
      strm.avail_in = #chunk
      repeat
        strm.next_out = ffi.cast("Bytef *", buf)
        strm.avail_out = CHUNK
        ret = zlib.inflate(strm, Z_NO_FLUSH)
        if ret == Z_STREAM_END then
          local have = CHUNK - strm.avail_out
          if have > 0 then
            chunks[#chunks + 1] = ffi.string(buf, have)
          end
          finished = true
          zlib.inflateEnd(strm)
          return true
        end
        if ret ~= Z_OK then
          zlib.inflateEnd(strm)
          local msg = strm.msg ~= nil and ffi.string(strm.msg) or ("code " .. ret)
          return nil, "inflate failed: " .. msg
        end
        local have = CHUNK - strm.avail_out
        if have > 0 then
          chunks[#chunks + 1] = ffi.string(buf, have)
        end
      until strm.avail_out ~= 0
      return true
    end,
    --: () -> string | nil, string | nil
    finish = function()
      if not finished then
        finished = true
        zlib.inflateEnd(strm)
      end
      return table.concat(chunks)
    end,
  }
end

local M = {}
M.deflate = deflate
M.inflate = inflate
M.encode = deflate
M.decode = inflate
M.deflater = deflater
M.inflater = inflater
M._tier = "system-zlib"
M._loaded_from = zlib_loaded_from
return M
