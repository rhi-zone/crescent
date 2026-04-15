-- lib/zstd/init.lua
-- Zstandard compression/decompression (RFC 8878).
-- Used for HTTP Content-Encoding: zstd and many storage formats.
--
-- Tiers (selected at load time, best available wins):
--   system — FFI to libzstd (fastest; requires shared lib)
--   stub   — libzstd not available; all ops return nil, errmsg
--
-- Public API:
--   M.compress(input, opts)    -> compressed, nil  OR  nil, errmsg
--   M.decompress(compressed)   -> decompressed, nil  OR  nil, errmsg
--   M.is_zstd(data)            -> boolean
--   M.encode = M.compress      (codec alias)
--   M.decode  = M.decompress   (codec alias)
--   M._tier = "system" | "stub"
--
-- compress opts: { level = 3 }
--   level: 1-22 (default 3; 22 = best compression, slowest)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- ── Pure Lua frame detection ──────────────────────────────────────────────────

-- Zstd magic number: 0xFD2FB528 in little-endian = "\x28\xb5\x2f\xfd"
local ZSTD_MAGIC = "\x28\xb5\x2f\xfd"

--: (string) -> boolean
local function is_zstd(data)
  return type(data) == "string" and #data >= 4 and data:sub(1, 4) == ZSTD_MAGIC
end

-- ── FFI tier ──────────────────────────────────────────────────────────────────

local M = {}

-- Expose frame detection regardless of tier
M.is_zstd = is_zstd

local ok_ffi, ffi = pcall(require, "ffi")
if ok_ffi then
  pcall(ffi.cdef, [[
    size_t ZSTD_compress(void* dst, size_t dstCapacity,
                         const void* src, size_t srcSize, int compressionLevel);
    size_t ZSTD_decompress(void* dst, size_t dstCapacity,
                           const void* src, size_t compressedSize);
    size_t ZSTD_getFrameContentSize(const void* src, size_t srcSize);
    unsigned ZSTD_isError(size_t code);
    const char* ZSTD_getErrorName(size_t code);
    size_t ZSTD_compressBound(size_t srcSize);

    typedef struct ZSTD_CCtx_s ZSTD_CCtx;
    typedef struct ZSTD_DCtx_s ZSTD_DCtx;
    ZSTD_CCtx* ZSTD_createCCtx(void);
    void ZSTD_freeCCtx(ZSTD_CCtx* cctx);
    ZSTD_DCtx* ZSTD_createDCtx(void);
    void ZSTD_freeDCtx(ZSTD_DCtx* dctx);
  ]])

  -- Try to load a library by scanning multiple candidate paths/names.
  -- Returns: library handle or nil
  local function try_load(names, suffixes)
    -- 1. Standard names (works when the lib is on LD_LIBRARY_PATH)
    for _, name in ipairs(names) do
      local ok, lib = pcall(ffi.load, name)
      if ok then return lib end
    end

    -- 2. Scan LD_LIBRARY_PATH
    local ldpath = (os and os.getenv and os.getenv("LD_LIBRARY_PATH")) or ""
    for dir in (ldpath .. ":"):gmatch("([^:]*):") do
      if dir ~= "" then
        for _, suf in ipairs(suffixes) do
          local ok, lib = pcall(ffi.load, dir .. suf)
          if ok then return lib end
        end
      end
    end

    -- 3. Scan NIX_LDFLAGS (-L dirs)
    local ldflags = (os and os.getenv and os.getenv("NIX_LDFLAGS")) or ""
    for dir in ldflags:gmatch("-L(%S+)") do
      for _, suf in ipairs(suffixes) do
        local ok, lib = pcall(ffi.load, dir .. suf)
        if ok then return lib end
      end
    end

    -- 4. Common profile paths
    local home = (os and os.getenv and os.getenv("HOME")) or ""
    local profile_dirs = {
      "/run/current-system/sw/lib",
      home .. "/.nix-profile/lib",
      "/usr/lib",
      "/usr/lib/x86_64-linux-gnu",
      "/usr/lib/aarch64-linux-gnu",
      "/usr/local/lib",
      "/opt/local/lib",
      "/opt/homebrew/lib",
    }
    for _, dir in ipairs(profile_dirs) do
      for _, suf in ipairs(suffixes) do
        local ok, lib = pcall(ffi.load, dir .. suf)
        if ok then return lib end
      end
    end

    -- 5. Last resort: scan nix store (NixOS-specific; slow but reliable)
    local f = io.popen("find /nix/store -maxdepth 4 -name '" .. suffixes[1]:sub(2) .. "' 2>/dev/null | head -1")
    if f then
      local path = f:read("*l")
      f:close()
      if path and path ~= "" then
        local ok, lib = pcall(ffi.load, path)
        if ok then return lib end
      end
    end

    return nil
  end

  local zlib = try_load(
    { "zstd", "libzstd", "zstd1" },
    { "/libzstd.so.1", "/libzstd.so" }
  )

  if zlib then
    M._tier = "system"

    -- ZSTD_CONTENTSIZE_UNKNOWN = (unsigned long long)-1  = all-0xff
    -- ZSTD_CONTENTSIZE_ERROR   = (unsigned long long)-2  = all-0xff except last byte 0xfe
    -- Compare via ffi.cast to size_t to stay in C integer domain (avoids
    -- Lua double precision loss for these >2^53 values).
    -- The ULL suffix is valid LuaJIT runtime syntax but our typechecker lexer
    -- doesn't handle it, so we construct via ffi.cast from hex strings instead.
    local CONTENTSIZE_UNKNOWN = ffi.cast("size_t", ffi.cast("int64_t", -1))
    local CONTENTSIZE_ERROR   = ffi.cast("size_t", ffi.cast("int64_t", -2))

    -- ── compress ──────────────────────────────────────────────────────────────

    --: (string, table?) -> string?, string?
    function M.compress(input, opts)
      if type(input) ~= "string" then
        return nil, "zstd.compress: expected string"
      end
      opts = opts or {}
      local level = opts.level or 3

      local src_size = #input
      local dst_cap  = tonumber(zlib.ZSTD_compressBound(src_size))
      if dst_cap == 0 then dst_cap = src_size + 256 end
      local dst_buf = ffi.new("uint8_t[?]", dst_cap)

      local ret = zlib.ZSTD_compress(dst_buf, dst_cap, input, src_size, level)
      if zlib.ZSTD_isError(ret) ~= 0 then
        return nil, "zstd.compress: " .. ffi.string(zlib.ZSTD_getErrorName(ret))
      end
      return ffi.string(dst_buf, ret)
    end

    -- ── decompress ────────────────────────────────────────────────────────────

    --: (string) -> string?, string?
    function M.decompress(compressed)
      if type(compressed) ~= "string" then
        return nil, "zstd.decompress: expected string"
      end
      local src_size = #compressed

      -- Probe the frame content size.
      local content_size = zlib.ZSTD_getFrameContentSize(compressed, src_size)

      local dst_cap
      if content_size == CONTENTSIZE_ERROR then
        return nil, "zstd.decompress: not a valid zstd frame"
      elseif content_size == CONTENTSIZE_UNKNOWN then
        -- Size not stored in frame: start with 4x guess, grow as needed.
        dst_cap = src_size * 4 + 256
      else
        dst_cap = tonumber(content_size)
      end

      -- When size is known, one iteration suffices.
      -- When unknown, grow up to 8 doublings before giving up.
      local max_tries = content_size == CONTENTSIZE_UNKNOWN and 8 or 1
      for _ = 1, max_tries do
        if dst_cap < 64 then dst_cap = 64 end
        local dst_buf = ffi.new("uint8_t[?]", dst_cap)
        local ret = zlib.ZSTD_decompress(dst_buf, dst_cap, compressed, src_size)
        if zlib.ZSTD_isError(ret) == 0 then
          return ffi.string(dst_buf, ret)
        end
        local errmsg = ffi.string(zlib.ZSTD_getErrorName(ret))
        -- "Destination buffer is too small" → retry with larger buffer
        if errmsg:find("too small") or errmsg:find("Destination buffer") then
          dst_cap = dst_cap * 8
        else
          return nil, "zstd.decompress: " .. errmsg
        end
      end
      return nil, "zstd.decompress: decompressed output too large to fit in buffer"
    end
  end
end

-- ── Stub tier (fallback) ──────────────────────────────────────────────────────

if not M._tier then
  M._tier = "stub"

  --: (string, table?) -> nil, string
  function M.compress(_, _)
    return nil, "zstd: libzstd not available"
  end

  --: (string) -> nil, string
  function M.decompress(_)
    return nil, "zstd: libzstd not available"
  end
end

-- ── Codec aliases ─────────────────────────────────────────────────────────────

M.encode = M.compress
M.decode  = M.decompress

return M
