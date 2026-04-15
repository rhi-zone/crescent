-- lib/brotli/init.lua
-- Brotli compression/decompression (RFC 7932).
-- Used for HTTP Content-Encoding: br.
--
-- Tiers (selected at load time, best available wins):
--   system — FFI to libbrotlidec + libbrotlienc (fastest; requires shared libs)
--   stub   — neither tier available; all ops return nil, errmsg
--
-- Note: A full pure-Lua Brotli decompressor requires a 120KB static dictionary,
-- multiple Huffman trees, and complex prefix codes. Given that complexity, this
-- library falls through to a stub when the system libraries are not available.
-- Use lib/compress (zlib/gzip) or lib/snappy for pure-Lua compression.
--
-- Public API:
--   M.decompress(compressed)           -> decompressed, nil  OR  nil, errmsg
--   M.compress(input, opts)            -> compressed, nil    OR  nil, errmsg
--   M.encode = M.compress              (codec alias)
--   M.decode = M.decompress            (codec alias)
--   M._tier = "system" | "stub"
--
-- compress opts: { quality = 6, lgwin = 22, mode = 0 }
--   quality: 0-11 (default 6; 11 = best compression)
--   lgwin:   10-24 (default 22; sliding window size = 2^lgwin bytes)
--   mode:    0=generic, 1=text, 2=font (default 0)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- ── FFI tier ─────────────────────────────────────────────────────────────────

local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
if ok_ffi then
  -- Guard cdef against re-require (pcall absorbs "already defined" errors).
  pcall(ffi.cdef, [[
    int BrotliDecoderDecompress(
      size_t encoded_size, const uint8_t* encoded_buffer,
      size_t* decoded_size, uint8_t* decoded_buffer);

    int BrotliEncoderCompress(
      int quality, int lgwin, int mode,
      size_t input_size, const uint8_t* input_buffer,
      size_t* encoded_size, uint8_t* encoded_buffer);
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

  local dec_lib = try_load(
    { "brotlidec", "libbrotlidec", "brotli" },
    { "/libbrotlidec.so.1", "/libbrotlidec.so" }
  )
  local enc_lib = try_load(
    { "brotlienc", "libbrotlienc", "brotli" },
    { "/libbrotlienc.so.1", "/libbrotlienc.so" }
  )

  if dec_lib or enc_lib then
    M._tier = "system"

    -- ── decompress ────────────────────────────────────────────────────────────

    --: (string) -> string?, string?
    function M.decompress(compressed)
      if not dec_lib then
        return nil, "brotli: libbrotlidec not available"
      end
      if type(compressed) ~= "string" then
        return nil, "brotli.decompress: expected string"
      end
      local enc_size = #compressed

      -- Start with a 4x guess; grow if NEEDS_MORE_OUTPUT (but one-shot API
      -- returns 0 = error, 1 = success, so we retry with larger buffers).
      local factor = 4
      for _ = 1, 8 do
        local dec_max = enc_size * factor + 64
        if dec_max < 64 then dec_max = 64 end
        local dec_buf = ffi.new("uint8_t[?]", dec_max)
        local dec_size = ffi.new("size_t[1]", dec_max)
        local ret = dec_lib.BrotliDecoderDecompress(
          enc_size, compressed, dec_size, dec_buf)
        if ret == 1 then
          return ffi.string(dec_buf, dec_size[0])
        end
        -- ret == 0 could mean buffer too small or real error;
        -- try a larger buffer before giving up.
        factor = factor * 8
      end
      return nil, "brotli.decompress: decompression failed (invalid data or output too large)"
    end

    -- ── compress ──────────────────────────────────────────────────────────────

    --: (string, table?) -> string?, string?
    function M.compress(input, opts)
      if not enc_lib then
        return nil, "brotli: libbrotlienc not available"
      end
      if type(input) ~= "string" then
        return nil, "brotli.compress: expected string"
      end
      opts = opts or {}
      local quality = opts.quality or 6
      local lgwin   = opts.lgwin   or 22
      local mode    = opts.mode    or 0

      local inp_size = #input
      -- Conservative upper bound from the brotli docs
      local enc_max = inp_size + math.floor(inp_size / 4) + 10240
      if enc_max < 64 then enc_max = 64 end

      local enc_buf  = ffi.new("uint8_t[?]", enc_max)
      local enc_size = ffi.new("size_t[1]", enc_max)
      local ret = enc_lib.BrotliEncoderCompress(
        quality, lgwin, mode,
        inp_size, input,
        enc_size, enc_buf)
      if ret ~= 1 then
        return nil, "brotli.compress: compression failed"
      end
      return ffi.string(enc_buf, enc_size[0])
    end
  end
end

-- ── Stub tier (fallback) ─────────────────────────────────────────────────────

if not M._tier then
  M._tier = "stub"

  --: (string) -> nil, string
  function M.decompress(_)
    return nil, "brotli: libbrotlidec not available"
  end

  --: (string, table?) -> nil, string
  function M.compress(_, _)
    return nil, "brotli: libbrotlienc not available"
  end
end

-- ── Codec aliases ─────────────────────────────────────────────────────────────

M.encode = M.compress
M.decode  = M.decompress

return M
