-- lib/argon2/init.lua
-- Argon2 password hashing (RFC 9106).
-- Variants: Argon2d, Argon2i, Argon2id.
--
-- Public API:
--   M.hash(password, salt, opts)          -> binary_string | nil, errmsg
--   M.hash_encoded(password, salt, opts)  -> PHC_string    | nil, errmsg
--   M.verify(encoded, password)           -> true | false, errmsg
--   M.verify_raw(derived, password, salt, opts) -> boolean | nil, errmsg
--   M._tier = "system" | "pure" | "stub"
--
-- opts = {
--   variant  = "id"|"i"|"d"  (default "id")
--   t        = integer        (time cost,       default 3)
--   m        = integer        (memory KB,       default 65536)
--   p        = integer        (parallelism,     default 4)
--   hash_len = integer        (output bytes,    default 32)
-- }
--
-- Tiers:
--   system — FFI to libargon2 (fastest; requires the shared library)
--   pure   — pure-Lua Argon2i, t=1 m=8 p=1 only (reference / test use)
--   stub   — neither tier available; all ops return nil, errmsg

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local base64 = require("lib.base64")

--: (...number) -> number
local function band(...) return bit.band(... --[[: any]]) end
--: (...number) -> number
local function bxor(...) return bit.bxor(... --[[: any]]) end
--: (...number) -> number
local function bor(...) return bit.bor(... --[[: any]]) end
--: (number, number) -> number
local function lshift(a, b) return bit.lshift(a --[[: any]], b --[[: any]]) end
--: (number, number) -> number
local function rshift(a, b) return bit.rshift(a --[[: any]], b --[[: any]]) end
--: (number) -> number
local function tobit(n) return bit.tobit(n --[[: any]]) end
local sbyte  = string.byte
local schar  = string.char
local sformat = string.format

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

local function to_hex(s)
  local str = s --[[:! string]]
  local t = {}
  for i = 1, #str do t[i] = sformat("%02x", sbyte(str, i) or 0) end
  return table.concat(t)
end

-- Constant-time comparison of two strings.
local function ct_eq(a, b)
  local sa = a --[[:! string]]
  local sb = b --[[:! string]]
  if #sa ~= #sb then return false end
  local diff = 0 --: number
  for i = 1, #sa do
    diff = bor(diff, bxor(sbyte(sa, i) or 0, sbyte(sb, i) or 0))
  end
  return diff == 0
end

-- Base64url (no padding) encode/decode.
--: (s: string) -> string
local function b64url_encode(s)
  return base64.encode(s, { url = true, pad = false }) --[[: string]]
end

--: (s: string) -> (string | nil)
local function b64url_decode(s)
  return base64.decode(s, { url = true }) --[[: string | nil]]
end

-- Parse a PHC-format Argon2 string:
-- $argon2id$v=19$m=65536,t=3,p=4$<base64salt>$<base64hash>
--: (encoded: string) -> ({ variant: string, v: number, m: number, t: number, p: number, salt: string, hash: string | nil } | nil, string | nil)
local function parse_phc(encoded)
  local s = encoded
  if s:sub(1, 1) ~= "$" then
    return nil, "invalid PHC string: must start with $"
  end
  s = s:sub(2)

  local fields = {}
  for part in (s .. "$"):gmatch("([^$]*)%$") do
    fields[#fields + 1] = part
  end
  -- fields: [1]=variant [2]=v=19 [3]=params [4]=b64salt [5]=b64hash
  if #fields < 5 then
    return nil, "invalid PHC string: expected 5 fields, got " .. #fields
  end

  local variant = fields[1]
  if variant ~= "argon2id" and variant ~= "argon2i" and variant ~= "argon2d" then
    return nil, "unknown Argon2 variant: " .. variant
  end

  local v = tonumber(fields[2]:match("^v=(%d+)$"))
  if not v then return nil, "invalid PHC string: bad version field" end

  local params = fields[3]
  local m = tonumber(params:match("m=(%d+)"))
  local t = tonumber(params:match("t=(%d+)"))
  local p = tonumber(params:match("p=(%d+)"))
  if not m then return nil, "invalid PHC string: bad params field" end
  if not t then return nil, "invalid PHC string: bad params field" end
  if not p then return nil, "invalid PHC string: bad params field" end

  local salt = b64url_decode(fields[4])
  if not salt then return nil, "invalid PHC string: bad salt base64" end

  local hash --: string | nil
  if fields[5] and fields[5] ~= "" then
    hash = b64url_decode(fields[5])
    if not hash then return nil, "invalid PHC string: bad hash base64" end
  end

  return {
    variant = variant:sub(7),  -- "id", "i", or "d"
    v = v,
    m = m,
    t = t,
    p = p,
    salt = salt,
    hash = hash,
  }
end

-- Build a PHC string from components.
local function build_phc(variant, t, m, p, salt, hash)
  return sformat("$argon2%s$v=19$m=%d,t=%d,p=%d$%s$%s",
    variant, m, t, p, b64url_encode(salt), b64url_encode(hash))
end

-- ---------------------------------------------------------------------------
-- System tier: FFI to libargon2
-- ---------------------------------------------------------------------------

-- set if libargon2 loads
local system_lib --: any

local ok_ffi, _ffi_raw = pcall(require, "ffi")
local ffi = _ffi_raw --[[: any]]
if ok_ffi then
  local function try_load_argon2()
    local names = { "argon2", "libargon2", "argon2-1", "libargon2.so.1", "libargon2.so" }
    for _, name in ipairs(names) do
      local ok, l = pcall(ffi.load, name)
      if ok then return l end
    end
    -- Scan LD_LIBRARY_PATH
    local ldpath = os.getenv("LD_LIBRARY_PATH") or ""
    for dir in (ldpath .. ":"):gmatch("([^:]*):") do
      if dir ~= "" then
        for _, suf in ipairs({ "/libargon2.so.1", "/libargon2.so" }) do
          local ok, l = pcall(ffi.load, dir .. suf)
          if ok then return l end
        end
      end
    end
    -- Scan NIX_LDFLAGS (-L dirs)
    local ldflags = os.getenv("NIX_LDFLAGS") or ""
    for dir in ldflags:gmatch("-L(%S+)") do
      for _, suf in ipairs({ "/libargon2.so.1", "/libargon2.so" }) do
        local ok, l = pcall(ffi.load, dir .. suf)
        if ok then return l end
      end
    end
    -- Common profile paths
    local home = os.getenv("HOME") or ""
    local profiles = {
      "/run/current-system/sw/lib",
      home .. "/.nix-profile/lib",
      "/usr/lib",
      "/usr/local/lib",
    }
    for _, dir in ipairs(profiles) do
      for _, suf in ipairs({ "/libargon2.so.1", "/libargon2.so" }) do
        local ok, l = pcall(ffi.load, dir .. suf)
        if ok then return l end
      end
    end
    return nil
  end

  local candidate = try_load_argon2()
  if candidate then
    -- Only cdef once (guard against re-require with pcall).
    pcall(ffi.cdef, [[
      typedef enum {
        ARGON2_OK                  =  0,
        ARGON2_VERIFY_MISMATCH     = 32
      } argon2_error_codes;

      int argon2id_hash_raw(uint32_t t_cost, uint32_t m_cost, uint32_t parallelism,
        const void *pwd, size_t pwdlen,
        const void *salt, size_t saltlen,
        void *hash, size_t hashlen);

      int argon2i_hash_raw(uint32_t t_cost, uint32_t m_cost, uint32_t parallelism,
        const void *pwd, size_t pwdlen,
        const void *salt, size_t saltlen,
        void *hash, size_t hashlen);

      int argon2d_hash_raw(uint32_t t_cost, uint32_t m_cost, uint32_t parallelism,
        const void *pwd, size_t pwdlen,
        const void *salt, size_t saltlen,
        void *hash, size_t hashlen);

      int argon2id_hash_encoded(uint32_t t_cost, uint32_t m_cost, uint32_t parallelism,
        const void *pwd, size_t pwdlen,
        const void *salt, size_t saltlen,
        size_t hashlen, char *encoded, size_t encodedlen);

      int argon2i_hash_encoded(uint32_t t_cost, uint32_t m_cost, uint32_t parallelism,
        const void *pwd, size_t pwdlen,
        const void *salt, size_t saltlen,
        size_t hashlen, char *encoded, size_t encodedlen);

      int argon2d_hash_encoded(uint32_t t_cost, uint32_t m_cost, uint32_t parallelism,
        const void *pwd, size_t pwdlen,
        const void *salt, size_t saltlen,
        size_t hashlen, char *encoded, size_t encodedlen);

      int argon2id_verify(const char *encoded, const void *pwd, size_t pwdlen);
      int argon2i_verify(const char *encoded, const void *pwd, size_t pwdlen);
      int argon2d_verify(const char *encoded, const void *pwd, size_t pwdlen);

      const char *argon2_error_message(int error_code);
    ]])
    system_lib = candidate
  end
end

-- ---------------------------------------------------------------------------
-- BLAKE2b — minimal pure-Lua implementation for the pure tier
-- ---------------------------------------------------------------------------
-- Implements BLAKE2b(input, key, outlen) and H'(T, X) (variable-length hash).
-- Uses LuaJIT bit library. 64-bit words stored as {hi, lo} pairs (both signed i32).

-- 64-bit addition (wrapping): (ah,al) + (bh,bl) -> rh, rl
local function add64(ah, al, bh, bl)
  local ual = al < 0 and al + 0x100000000 or al
  local ubl = bl < 0 and bl + 0x100000000 or bl
  local carry = (ual + ubl >= 0x100000000) and 1 or 0
  return tobit(ah + bh + carry), tobit(al + bl)
end

-- 64-bit rotate right by n bits.
local function rotr64(ah, al, n)
  if n == 32 then return al, ah end
  if n < 32 then
    return tobit(bor(rshift(ah, n), lshift(al, 32-n))),
           tobit(bor(rshift(al, n), lshift(ah, 32-n)))
  end
  n = n - 32
  return tobit(bor(rshift(al, n), lshift(ah, 32-n))),
         tobit(bor(rshift(ah, n), lshift(al, 32-n)))
end

-- BLAKE2b initialization vector (IV).
local B2IV = { --: { [integer]: { [integer]: number } }
  {tobit(0x6a09e667), tobit(0xf3bcc908)},
  {tobit(0xbb67ae85), tobit(0x84caa73b)},
  {tobit(0x3c6ef372), tobit(0xfe94f82b)},
  {tobit(0xa54ff53a), tobit(0x5f1d36f1)},
  {tobit(0x510e527f), tobit(0xade682d1)},
  {tobit(0x9b05688c), tobit(0x2b3e6c1f)},
  {tobit(0x1f83d9ab), tobit(0xfb41bd6b)},
  {tobit(0x5be0cd19), tobit(0x137e2179)},
}

-- BLAKE2b sigma permutation (12 rounds x 16 message-word indices).
local B2SIGMA = {
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15},
  {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3},
  {11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4},
  { 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8},
  { 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13},
  { 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9},
  {12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11},
  {13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10},
  { 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5},
  {10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13, 0},
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15},
  {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3},
}

-- BLAKE2b G mixing function. v is a table of 16 {hi,lo} pairs (1-indexed).
local function b2G(v, ai, bi, ci, di, xh, xl, yh, yl)
  local ah, al = add64(v[ai][1], v[ai][2], v[bi][1], v[bi][2])
  ah, al = add64(ah, al, xh, xl)
  v[ai][1], v[ai][2] = ah, al
  local dh, dl = bxor(v[di][1], ah), bxor(v[di][2], al)
  dh, dl = rotr64(dh, dl, 32)
  v[di][1], v[di][2] = dh, dl
  local ch, cl = add64(v[ci][1], v[ci][2], dh, dl)
  v[ci][1], v[ci][2] = ch, cl
  local bh, bl = bxor(v[bi][1], ch), bxor(v[bi][2], cl)
  bh, bl = rotr64(bh, bl, 24)
  v[bi][1], v[bi][2] = bh, bl
  ah, al = add64(v[ai][1], v[ai][2], bh, bl)
  ah, al = add64(ah, al, yh, yl)
  v[ai][1], v[ai][2] = ah, al
  dh, dl = bxor(v[di][1], ah), bxor(v[di][2], al)
  dh, dl = rotr64(dh, dl, 16)
  v[di][1], v[di][2] = dh, dl
  ch, cl = add64(v[ci][1], v[ci][2], dh, dl)
  v[ci][1], v[ci][2] = ch, cl
  bh, bl = bxor(v[bi][1], ch), bxor(v[bi][2], cl)
  bh, bl = rotr64(bh, bl, 63)
  v[bi][1], v[bi][2] = bh, bl
end

-- BLAKE2b compression function. h[1..8] are {hi,lo} state words.
-- m[0..15] are {hi,lo} message words (0-indexed to match sigma).
-- t_lo, t_hi: byte counter (low 64 bits). f: finalization flag.
--: (h: { [integer]: { [integer]: number } }, m: { [integer]: { [integer]: number } }, t_lo: number, t_hi: number, f: boolean) -> nil
local function b2compress(h, m, t_lo, t_hi, f)
  local v = {} --: { [integer]: { [integer]: number } }
  for i = 1, 8 do v[i] = {h[i][1], h[i][2]} end
  for i = 1, 8 do v[8+i] = {B2IV[i][1], B2IV[i][2]} end
  v[13][1] = bxor(v[13][1], t_hi)
  v[13][2] = bxor(v[13][2], t_lo)
  if f then
    v[15][1] = bxor(v[15][1], tobit(0xFFFFFFFF))
    v[15][2] = bxor(v[15][2], tobit(0xFFFFFFFF))
  end
  for r = 1, 12 do
    local s = B2SIGMA[r]
    b2G(v,  1,  5,  9, 13, m[s[1]][1], m[s[1]][2], m[s[2]][1],  m[s[2]][2])
    b2G(v,  2,  6, 10, 14, m[s[3]][1], m[s[3]][2], m[s[4]][1],  m[s[4]][2])
    b2G(v,  3,  7, 11, 15, m[s[5]][1], m[s[5]][2], m[s[6]][1],  m[s[6]][2])
    b2G(v,  4,  8, 12, 16, m[s[7]][1], m[s[7]][2], m[s[8]][1],  m[s[8]][2])
    b2G(v,  1,  6, 11, 16, m[s[9]][1], m[s[9]][2], m[s[10]][1], m[s[10]][2])
    b2G(v,  2,  7, 12, 13, m[s[11]][1],m[s[11]][2],m[s[12]][1], m[s[12]][2])
    b2G(v,  3,  8,  9, 14, m[s[13]][1],m[s[13]][2],m[s[14]][1], m[s[14]][2])
    b2G(v,  4,  5, 10, 15, m[s[15]][1],m[s[15]][2],m[s[16]][1], m[s[16]][2])
  end
  for i = 1, 8 do
    h[i][1] = bxor(h[i][1], v[i][1], v[8+i][1])
    h[i][2] = bxor(h[i][2], v[i][2], v[8+i][2])
  end
end

-- BLAKE2b(input, key, outlen) -> binary string.
-- key: optional string (0..64 bytes), outlen: 1..64 bytes.
--: (input: string, key: string | nil, outlen: number | nil) -> string
local function blake2b(input, key, outlen)
  outlen = outlen or 64
  key = key or ""
  local kk = #key

  local h = {} --: { [integer]: { [integer]: number } }
  for i = 1, 8 do h[i] = {B2IV[i][1], B2IV[i][2]} end
  -- Parameter block word 0: digest_len | key_len<<8 | fan_out<<16 | max_depth<<24
  -- For sequential hashing: fan_out=1, max_depth=1 (both 1 by default in blake2b)
  -- = outlen | (kk<<8) | (1<<16) | (1<<24) = 0x01010000 | (kk<<8) | outlen
  h[1][2] = bxor(h[1][2], bxor(0x01010000, lshift(kk, 8), outlen))

  local data = kk > 0 and (key .. string.rep("\0", 128 - kk) .. input) or input
  local data_len = #data

  local num_blocks = math.max(1, math.ceil((data_len == 0 and 1 or data_len) / 128))
  for blk = 1, num_blocks do
    local base = (blk - 1) * 128
    local is_last = (blk == num_blocks)
    local block_str = data:sub(base + 1, base + 128)
    if #block_str < 128 then
      block_str = block_str .. string.rep("\0", 128 - #block_str)
    end
    -- Parse block into m[0..15] {hi, lo} (LE 64-bit words).
    local m = {} --: { [integer]: { [integer]: number } }
    for i = 0, 15 do
      local pos = i * 8 + 1
      local _b0,_b1,_b2,_b3,_b4,_b5,_b6,_b7 = sbyte(block_str, pos, pos+7)
      local b0,b1,b2,b3,b4,b5,b6,b7 = _b0 or 0,_b1 or 0,_b2 or 0,_b3 or 0,_b4 or 0,_b5 or 0,_b6 or 0,_b7 or 0
      m[i] = {tobit(b4 + b5*0x100 + b6*0x10000 + b7*0x1000000),
              tobit(b0 + b1*0x100 + b2*0x10000 + b3*0x1000000)}
    end
    -- Counter = total bytes consumed so far (capped at actual data length).
    local cnt = is_last and data_len or math.min(blk * 128, data_len)
    if data_len == 0 then cnt = 0 end
    b2compress(h, m, tobit(cnt), 0, is_last)
  end

  -- Extract output bytes (little-endian words).
  local out = {}
  local bytes_left = outlen
  for i = 1, 8 do
    if bytes_left <= 0 then break end
    local hi, lo = h[i][1], h[i][2]
    local ulo = lo < 0 and lo + 0x100000000 or lo
    local uhi = hi < 0 and hi + 0x100000000 or hi
    local take = math.min(bytes_left, 8)
    local wb = {
      band(ulo, 0xff), band(rshift(ulo, 8), 0xff),
      band(rshift(ulo, 16), 0xff), band(rshift(ulo, 24), 0xff),
      band(uhi, 0xff), band(rshift(uhi, 8), 0xff),
      band(rshift(uhi, 16), 0xff), band(rshift(uhi, 24), 0xff),
    }
    for j = 1, take do out[#out+1] = schar(wb[j]) end
    bytes_left = bytes_left - take
  end
  return table.concat(out)
end

-- Variable-length hash H'(T_len, X) per RFC 9106 §3.2.
-- Returns T_len bytes of output.
local function H_prime(T_len, X)
  local len_str = schar(
    band(T_len, 0xff), band(rshift(T_len, 8), 0xff),
    band(rshift(T_len, 16), 0xff), band(rshift(T_len, 24), 0xff)
  )
  if T_len <= 64 then
    return blake2b(len_str .. X, nil, T_len)
  end
  -- T_len > 64: chain of 64-byte BLAKE2b calls.
  local r = math.ceil(T_len / 32) - 2
  local A = blake2b(len_str .. X, nil, 64)
  local out = {A:sub(1, 32)}
  local prev = A
  for _ = 2, r do
    local Ai = blake2b(prev, nil, 64)
    out[#out+1] = Ai:sub(1, 32)
    prev = Ai
  end
  local last_len = T_len - 32 * r
  if last_len > 0 then
    out[#out+1] = blake2b(prev, nil, last_len)
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Pure Lua tier: Argon2i reference (t=1, m=8, p=1 only)
-- ---------------------------------------------------------------------------
-- Implements RFC 9106 §3 using the fill_block algorithm from the reference.
-- Restricted to t=1, m=8, p=1 to keep the code size reasonable.
-- Each 1024-byte block is stored as a table of 128 {hi,lo} pairs (1-indexed).

-- Encode a 32-bit integer as 4 LE bytes.
local function le32(n)
  return schar(
    band(n, 0xff), band(rshift(n, 8), 0xff),
    band(rshift(n, 16), 0xff), band(rshift(n, 24), 0xff)
  )
end

-- Allocate a zero-initialized 1024-byte block.
--: () -> { [integer]: { [integer]: number } }
local function new_block()
  local b = {} --: { [integer]: { [integer]: number } }
  for i = 1, 128 do b[i] = {0, 0} end
  return b
end

-- Copy block src into dst.
local function block_copy(dst, src)
  for i = 1, 128 do dst[i][1] = src[i][1]; dst[i][2] = src[i][2] end
end

-- XOR dst with src in-place.
local function block_xor_into(dst, src)
  for i = 1, 128 do
    dst[i][1] = bxor(dst[i][1], src[i][1])
    dst[i][2] = bxor(dst[i][2], src[i][2])
  end
end

-- Deserialize a 1024-byte string into a block.
local function string_to_block(s)
  local b = {}
  for i = 1, 128 do
    local pos = (i - 1) * 8 + 1
    local b0,b1,b2,b3,b4,b5,b6,b7 = sbyte(s, pos, pos+7)
    b0=b0 or 0; b1=b1 or 0; b2=b2 or 0; b3=b3 or 0
    b4=b4 or 0; b5=b5 or 0; b6=b6 or 0; b7=b7 or 0
    b[i] = {tobit(b4 + b5*0x100 + b6*0x10000 + b7*0x1000000),
            tobit(b0 + b1*0x100 + b2*0x10000 + b3*0x1000000)}
  end
  return b
end

-- Serialize a block to a 1024-byte string.
local function block_to_string(b)
  local t = {}
  for i = 1, 128 do
    local hi, lo = b[i][1], b[i][2]
    local ulo = lo < 0 and lo + 0x100000000 or lo
    local uhi = hi < 0 and hi + 0x100000000 or hi
    t[i] = schar(
      band(ulo, 0xff), band(rshift(ulo, 8), 0xff),
      band(rshift(ulo, 16), 0xff), band(rshift(ulo, 24), 0xff),
      band(uhi, 0xff), band(rshift(uhi, 8), 0xff),
      band(rshift(uhi, 16), 0xff), band(rshift(uhi, 24), 0xff)
    )
  end
  return table.concat(t)
end

-- fBlaMka multiplication: (low32(x) * low32(y)) << 1 as 64-bit.
-- Returns hi, lo.
local function fBlaMka_mul(xh, xl, yh, yl)
  local uxl = xl < 0 and xl + 0x100000000 or xl
  local uyl = yl < 0 and yl + 0x100000000 or yl
  -- Multiply 32-bit unsigned values using 16-bit chunks.
  local xh16 = math.floor(uxl / 0x10000)
  local xl16 = band(uxl, 0xFFFF)
  local yh16 = math.floor(uyl / 0x10000)
  local yl16 = band(uyl, 0xFFFF)
  local ll = xl16 * yl16
  local lh = xh16 * yl16 + xl16 * yh16
  local hh = xh16 * yh16
  -- Assemble 64-bit product (only low 64 bits needed).
  local lh_lo = band(lh, 0xFFFF)
  local lh_hi = math.floor(lh / 0x10000)
  local lo_raw = ll + lh_lo * 0x10000
  local lo_carry = math.floor(lo_raw / 0x100000000)
  local prod_lo = tobit(lo_raw)
  local prod_hi = tobit(hh + lh_hi + lo_carry)
  -- Multiply product by 2 (left shift 1).
  local m2_hi = tobit(lshift(prod_hi, 1) + (prod_lo < 0 and 1 or rshift(prod_lo, 31)))
  local m2_lo = tobit(lshift(prod_lo, 1))
  return m2_hi, m2_lo
end

-- Argon2 fBlaMka G function (RFC 9106 §3.4).
-- Operates on block b (table of 128 {hi,lo}) at 1-indexed positions a,b_,c,d.
-- G(v[a], v[b], v[c], v[d]):
--   a = a + b + 2*mul_lower(a,b); d = rotr64(d^a, 32)
--   c = c + d + 2*mul_lower(c,d); b = rotr64(b^c, 24)
--   a = a + b + 2*mul_lower(a,b); d = rotr64(d^a, 16)
--   c = c + d + 2*mul_lower(c,d); b = rotr64(b^c, 63)
local function blamka_G(blk, ai, bi, ci, di)
  -- a = a + b + 2*mul_lower(a,b)
  local ah, al = blk[ai][1], blk[ai][2]
  local bh, bl = blk[bi][1], blk[bi][2]
  local m2h, m2l = fBlaMka_mul(ah, al, bh, bl)
  ah, al = add64(ah, al, bh, bl)
  ah, al = add64(ah, al, m2h, m2l)
  blk[ai][1], blk[ai][2] = ah, al
  -- d = rotr64(d ^ a, 32)
  local dh = bxor(blk[di][1], ah)
  local dl = bxor(blk[di][2], al)
  dh, dl = rotr64(dh, dl, 32)
  blk[di][1], blk[di][2] = dh, dl
  -- c = c + d + 2*mul_lower(c,d)
  local ch, cl = blk[ci][1], blk[ci][2]
  m2h, m2l = fBlaMka_mul(ch, cl, dh, dl)
  ch, cl = add64(ch, cl, dh, dl)
  ch, cl = add64(ch, cl, m2h, m2l)
  blk[ci][1], blk[ci][2] = ch, cl
  -- b = rotr64(b ^ c, 24)
  bh = bxor(blk[bi][1], ch)
  bl = bxor(blk[bi][2], cl)
  bh, bl = rotr64(bh, bl, 24)
  blk[bi][1], blk[bi][2] = bh, bl
  -- a = a + b + 2*mul_lower(a,b)
  ah, al = blk[ai][1], blk[ai][2]
  bh, bl = blk[bi][1], blk[bi][2]
  m2h, m2l = fBlaMka_mul(ah, al, bh, bl)
  ah, al = add64(ah, al, bh, bl)
  ah, al = add64(ah, al, m2h, m2l)
  blk[ai][1], blk[ai][2] = ah, al
  -- d = rotr64(d ^ a, 16)
  dh = bxor(blk[di][1], ah)
  dl = bxor(blk[di][2], al)
  dh, dl = rotr64(dh, dl, 16)
  blk[di][1], blk[di][2] = dh, dl
  -- c = c + d + 2*mul_lower(c,d)
  ch, cl = blk[ci][1], blk[ci][2]
  m2h, m2l = fBlaMka_mul(ch, cl, dh, dl)
  ch, cl = add64(ch, cl, dh, dl)
  ch, cl = add64(ch, cl, m2h, m2l)
  blk[ci][1], blk[ci][2] = ch, cl
  -- b = rotr64(b ^ c, 63)
  bh = bxor(blk[bi][1], ch)
  bl = bxor(blk[bi][2], cl)
  bh, bl = rotr64(bh, bl, 63)
  blk[bi][1], blk[bi][2] = bh, bl
end

-- Apply P (the BLAMka permutation) to all 8 columns of a block.
-- Column i (0-indexed): words at positions 16*i+1 .. 16*i+16 (1-indexed).
-- PERMUTATION_P(v0..v15): G(v0,v4,v8,v12); G(v1,v5,v9,v13); G(v2,v6,v10,v14); G(v3,v7,v11,v15);
--                          G(v0,v5,v10,v15); G(v1,v6,v11,v12); G(v2,v7,v8,v13); G(v3,v4,v9,v14);
local function apply_columns(blk)
  for col = 0, 7 do
    local b = col * 16 + 1  -- 1-indexed base
    blamka_G(blk, b,   b+4,  b+8,  b+12)
    blamka_G(blk, b+1, b+5,  b+9,  b+13)
    blamka_G(blk, b+2, b+6,  b+10, b+14)
    blamka_G(blk, b+3, b+7,  b+11, b+15)
    blamka_G(blk, b,   b+5,  b+10, b+15)
    blamka_G(blk, b+1, b+6,  b+11, b+12)
    blamka_G(blk, b+2, b+7,  b+8,  b+13)
    blamka_G(blk, b+3, b+4,  b+9,  b+14)
  end
end

-- Apply P to all 8 rows of a block.
-- Row i (0-indexed): PERMUTATION_P_ROW uses base=2*i (0-indexed), selecting:
-- base, base+1, base+16, base+17, base+32, base+33, base+48, base+49,
-- base+64, base+65, base+80, base+81, base+96, base+97, base+112, base+113
-- These are 0-indexed; add 1 for our 1-indexed table.
local function apply_rows(blk)
  for row = 0, 7 do
    local base = 2 * row  -- 0-indexed
    local v0  = base + 1
    local v1  = base + 2
    local v2  = base + 17
    local v3  = base + 18
    local v4  = base + 33
    local v5  = base + 34
    local v6  = base + 49
    local v7  = base + 50
    local v8  = base + 65
    local v9  = base + 66
    local v10 = base + 81
    local v11 = base + 82
    local v12 = base + 97
    local v13 = base + 98
    local v14 = base + 113
    local v15 = base + 114
    blamka_G(blk, v0, v4,  v8,  v12)
    blamka_G(blk, v1, v5,  v9,  v13)
    blamka_G(blk, v2, v6,  v10, v14)
    blamka_G(blk, v3, v7,  v11, v15)
    blamka_G(blk, v0, v5,  v10, v15)
    blamka_G(blk, v1, v6,  v11, v12)
    blamka_G(blk, v2, v7,  v8,  v13)
    blamka_G(blk, v3, v4,  v9,  v14)
  end
end

-- fill_block(prev, ref, next, with_xor):
--   blockR = ref XOR prev
--   if with_xor: tmp = blockR XOR next  else: tmp = blockR
--   Apply columns then rows to blockR.
--   next = tmp XOR blockR
-- (RFC 9106 §3.4; mirrors OpenSSL fill_block)
local function fill_block(prev, ref, next_blk, with_xor)
  -- blockR = ref XOR prev
  local blockR = new_block()
  for i = 1, 128 do
    blockR[i][1] = bxor(ref[i][1], prev[i][1])
    blockR[i][2] = bxor(ref[i][2], prev[i][2])
  end
  -- tmp = blockR (copy), optionally XOR with next for pass >0
  local tmp = new_block()
  block_copy(tmp, blockR)
  if with_xor then
    block_xor_into(tmp, next_blk)
  end
  -- Apply P: columns then rows
  apply_columns(blockR)
  apply_rows(blockR)
  -- next = tmp XOR blockR
  block_copy(next_blk, tmp)
  block_xor_into(next_blk, blockR)
end

-- next_addresses(address_block, input_block, zero_block):
-- Generate a new batch of pseudo-random indices.
-- (RFC 9106 §3.3 data-independent addressing; mirrors OpenSSL next_addresses)
local function next_addresses(address_block, input_block, zero_block)
  -- input_block.v[6]++ (0-indexed word 6 = 1-indexed word 7)
  local ih, il = input_block[7][1], input_block[7][2]
  local ulo = il < 0 and il + 0x100000000 or il
  ulo = ulo + 1
  input_block[7][1] = tobit(ih + math.floor(ulo / 0x100000000))
  input_block[7][2] = tobit(ulo)
  -- Two rounds of fill_block with zero input
  fill_block(zero_block, input_block, address_block, false)
  fill_block(zero_block, address_block, address_block, false)
end

-- index_alpha: map pseudo_rand to a reference block index.
-- Mirrors OpenSSL index_alpha for pass=0, single lane.
-- Returns a 0-indexed block index within the lane.
local function index_alpha(pass, slice, j, seg_len, lane_len, pseudo_rand)
  local ref_area_sz
  if pass == 0 then
    if slice == 0 then
      ref_area_sz = j - 1
    else
      -- same_lane (only one lane)
      ref_area_sz = slice * seg_len + j - 1
    end
  else
    -- pass > 0 (not needed for t=1, but kept for correctness)
    ref_area_sz = lane_len - seg_len + j - 1
  end
  if ref_area_sz < 0 then ref_area_sz = 0 end

  local rel_pos = pseudo_rand
  -- rel_pos = pseudo_rand * pseudo_rand >> 32
  -- pseudo_rand is uint32; multiply using 16-bit chunks.
  local u = pseudo_rand < 0 and pseudo_rand + 0x100000000 or pseudo_rand
  local hi16 = math.floor(u / 0x10000)
  local lo16 = band(u, 0xFFFF)
  local sq_hi = hi16*hi16 + math.floor(2*hi16*lo16 / 0x10000)
  -- sq_hi is (pseudo_rand^2) >> 32
  rel_pos = ref_area_sz - 1 - math.floor(ref_area_sz * sq_hi / 0x100000000)
  if rel_pos < 0 then rel_pos = 0 end

  -- start_pos = 0 for pass=0 (or for the first slice of pass>0 with no wrap)
  local start_pos = 0
  if pass > 0 then
    if slice ~= 3 then  -- ARGON2_SYNC_POINTS - 1 = 3
      start_pos = (slice + 1) * seg_len
    end
  end
  return (start_pos + rel_pos) % lane_len
end

-- Pure Lua Argon2i (variant="i"), t=1, m=8, p=1 only.
--: (string, string, number, number, number, number) -> (string | nil, string)
local function argon2i_pure(password, salt, t, m, p, hash_len)
  if t ~= 1 then
    return nil, "pure tier: time cost must be 1, got " .. t
  end
  if m ~= 8 then
    return nil, "pure tier: memory cost must be 8 KB, got " .. m
  end
  if p ~= 1 then
    return nil, "pure tier: parallelism must be 1, got " .. p
  end

  -- Step 1: H0 (64-byte pre-hash).
  -- H0 = BLAKE2b-64(LE32(p)||LE32(hash_len)||LE32(m)||LE32(t)||LE32(v)||LE32(y)||
  --                 LE32(|P|)||P||LE32(|S|)||S||LE32(0)||LE32(0))
  local v_ver = 0x13  -- version 19
  local y_type = 1    -- Argon2i type

  local H0 = blake2b(
    le32(p) .. le32(hash_len) .. le32(m) .. le32(t) .. le32(v_ver) .. le32(y_type) ..
    le32(#password) .. password ..
    le32(#salt) .. salt ..
    le32(0) .. le32(0),
    nil, 64)

  -- Step 2: m' = floor(m / (4*p)) * 4*p blocks; for p=1, m=8 → m'=8.
  local m_prime = math.floor(m / (4 * p)) * (4 * p)
  if m_prime < 4 * p then m_prime = 4 * p end
  local q = m_prime  -- lane_length = m' for p=1
  local seg_len = q / 4  -- segment_length

  -- Step 3: Initialize first two blocks via H'.
  -- B[l][0] = H'(1024, H0 || LE32(0) || LE32(l))
  -- B[l][1] = H'(1024, H0 || LE32(1) || LE32(l))
  -- For p=1, l=0.
  local B = {} --: { [integer]: { [integer]: { [integer]: number } } }
  B[1] = string_to_block(H_prime(1024, H0 .. le32(0) .. le32(0)))
  B[2] = string_to_block(H_prime(1024, H0 .. le32(1) .. le32(0)))
  for i = 3, q do B[i] = new_block() end

  -- Step 4: Fill memory (1 pass for t=1).
  -- For Argon2i: use data-independent addressing with pseudo-random address blocks.
  local zero_blk = new_block()
  local input_blk = new_block()
  local addr_blk = new_block()

  -- For pass=0 (the only pass for t=1):
  for slice = 0, 3 do
    -- Initialize input block for this segment.
    for i = 1, 128 do input_blk[i][1] = 0; input_blk[i][2] = 0 end
    -- Words (0-indexed): [0]=pass, [1]=lane, [2]=slice, [3]=q, [4]=t, [5]=type
    input_blk[1][2] = 0       -- pass=0
    input_blk[2][2] = 0       -- lane=0
    input_blk[3][2] = slice
    input_blk[4][2] = q       -- memory_blocks
    input_blk[5][2] = t       -- passes (= t_cost = 1)
    input_blk[6][2] = y_type  -- type = Argon2i = 1
    -- word[6] (0-indexed) = input_blk[7] (1-indexed) is the counter; starts at 0.

    local start_j = 0
    -- For pass=0, slice=0: skip the first 2 positions (already initialized).
    if slice == 0 then start_j = 2 end

    -- Generate first address block for this segment.
    -- next_addresses increments input_blk[7] before computing.
    for i = 1, 128 do addr_blk[i][1] = 0; addr_blk[i][2] = 0 end
    next_addresses(addr_blk, input_blk, zero_blk)

    local seg_start = slice * seg_len

    for j = start_j, seg_len - 1 do
      local curr = seg_start + j  -- 0-indexed current block
      -- Regenerate address block when needed (every 128 positions within segment).
      if j > start_j and j % 128 == 0 then
        next_addresses(addr_blk, input_blk, zero_blk)
      end

      -- J1 = low 32 bits of address_block[j % 128] (0-indexed word j%128 = 1-indexed j%128+1)
      local addr_word = addr_blk[(j % 128) + 1]
      local J1 = addr_word[2]  -- lo word = low 32 bits

      -- prev_offset: previous block in the lane
      local prev_offset
      if curr % q == 0 then
        prev_offset = q - 1  -- wrap: last block in lane (0-indexed)
      else
        prev_offset = curr - 1
      end

      -- Reference block index (0-indexed).
      local ref_idx = index_alpha(0, slice, j, seg_len, q, J1)

      -- B[curr+1] = fill_block(B[prev+1], B[ref+1], B[curr+1], false)
      fill_block(B[prev_offset + 1], B[ref_idx + 1], B[curr + 1], false)
    end
  end

  -- Step 5: Final block = XOR of last column blocks for each lane.
  -- For p=1: just B[q] (the last block, 1-indexed).
  local C = block_to_string(B[q])

  -- Step 6: Output = H'(hash_len, C).
  return H_prime(hash_len, C)
end

-- ---------------------------------------------------------------------------
-- Module construction
-- ---------------------------------------------------------------------------

local M = {}

local DEFAULT_OPTS = {
  variant = "id",
  t = 3,
  m = 65536,
  p = 4,
  hash_len = 32,
}

--: (opts: { variant: string | nil, t: number | nil, m: number | nil, p: number | nil, hash_len: number | nil } | nil) -> ({ variant: string, t: number, m: number, p: number, hash_len: number } | nil, string | nil)
local function parse_opts(opts)
  local o = opts or { variant = nil, t = nil, m = nil, p = nil, hash_len = nil }
  local variant  = o.variant  or DEFAULT_OPTS.variant
  local t        = o.t        or DEFAULT_OPTS.t
  local m        = o.m        or DEFAULT_OPTS.m
  local p        = o.p        or DEFAULT_OPTS.p
  local hash_len = o.hash_len or DEFAULT_OPTS.hash_len

  if variant ~= "id" and variant ~= "i" and variant ~= "d" then
    return nil, "invalid variant: expected 'id', 'i', or 'd', got '" .. tostring(variant) .. "'"
  end
  if type(t) ~= "number" or t < 1 then
    return nil, "t (time cost) must be >= 1"
  end
  if type(m) ~= "number" or m < 8 then
    return nil, "m (memory cost) must be >= 8 KB"
  end
  if type(p) ~= "number" or p < 1 then
    return nil, "p (parallelism) must be >= 1"
  end
  if type(hash_len) ~= "number" or hash_len < 4 then
    return nil, "hash_len must be >= 4"
  end
  return { variant = variant, t = t, m = m, p = p, hash_len = hash_len }
end

if system_lib then
  -- ── System tier ────────────────────────────────────────────────────────────
  M._tier = "system"

  local raw_fns = { --: { [string]: any }
    id = system_lib.argon2id_hash_raw,
    i  = system_lib.argon2i_hash_raw,
    d  = system_lib.argon2d_hash_raw,
  }
  local enc_fns = { --: { [string]: any }
    id = system_lib.argon2id_hash_encoded,
    i  = system_lib.argon2i_hash_encoded,
    d  = system_lib.argon2d_hash_encoded,
  }
  local ver_fns = { --: { [string]: any }
    id = system_lib.argon2id_verify,
    i  = system_lib.argon2i_verify,
    d  = system_lib.argon2d_verify,
  }

  local function errmsg(code)
    return ffi.string(system_lib.argon2_error_message(code))
  end

  function M.hash(password, salt, opts)
    if type(password) ~= "string" then return nil, "password must be a string" end
    if type(salt) ~= "string" then return nil, "salt must be a string" end
    local o, err = parse_opts(opts)
    if not o then return nil, err end
    if #salt < 8 then return nil, "salt must be at least 8 bytes (RFC 9106)" end

    local buf = ffi.new("uint8_t[?]", o.hash_len)
    local fn = raw_fns[o.variant]
    local rc = fn(o.t, o.m, o.p, password, #password, salt, #salt, buf, o.hash_len)
    if rc ~= 0 then return nil, errmsg(rc) end
    return ffi.string(buf, o.hash_len)
  end

  function M.hash_encoded(password, salt, opts)
    if type(password) ~= "string" then return nil, "password must be a string" end
    if type(salt) ~= "string" then return nil, "salt must be a string" end
    local o, err = parse_opts(opts)
    if not o then return nil, err end
    if #salt < 8 then return nil, "salt must be at least 8 bytes (RFC 9106)" end

    local enc_len = 128 + math.ceil(#salt * 4 / 3) + math.ceil(o.hash_len * 4 / 3)
    local buf = ffi.new("char[?]", enc_len)
    local fn = enc_fns[o.variant]
    local rc = fn(o.t, o.m, o.p, password, #password, salt, #salt, o.hash_len, buf, enc_len)
    if rc ~= 0 then return nil, errmsg(rc) end
    return ffi.string(buf)
  end

  function M.verify(encoded, password)
    if type(encoded) ~= "string" then return false, "encoded must be a string" end
    if type(password) ~= "string" then return false, "password must be a string" end
    local parsed, err = parse_phc(encoded)
    if not parsed then return false, err end
    local fn = ver_fns[parsed.variant]
    if not fn then return false, "unknown variant: " .. parsed.variant end
    local rc = fn(encoded, password, #password)
    if rc == 0 then
      return true
    elseif rc == 32 then  -- ARGON2_VERIFY_MISMATCH
      return false, "password mismatch"
    else
      return false, errmsg(rc)
    end
  end

  function M.verify_raw(derived, password, salt, opts)
    if type(derived) ~= "string" then return nil, "derived must be a string" end
    local computed, err = M.hash(password, salt, opts)
    if not computed then return nil, err end
    return ct_eq(derived, computed)
  end

else
  -- ── Pure tier ──────────────────────────────────────────────────────────────
  M._tier = "pure"

  function M.hash(password, salt, opts)
    if type(password) ~= "string" then return nil, "password must be a string" end
    if type(salt) ~= "string" then return nil, "salt must be a string" end
    local o, err = parse_opts(opts)
    if not o then return nil, err end
    if #salt < 8 then return nil, "salt must be at least 8 bytes (RFC 9106)" end

    if o.variant ~= "i" then
      return nil, "pure tier only supports variant='i' (Argon2i); install libargon2 for Argon2id/Argon2d"
    end
    return argon2i_pure(password, salt, o.t, o.m, o.p, o.hash_len)
  end

  function M.hash_encoded(password, salt, opts)
    local hash, err = M.hash(password, salt, opts)
    if not hash then return nil, err end
    local o = parse_opts(opts)
    return build_phc(o.variant, o.t, o.m, o.p, salt, hash)
  end

  function M.verify(encoded, password)
    if type(encoded) ~= "string" then return false, "encoded must be a string" end
    if type(password) ~= "string" then return false, "password must be a string" end
    local parsed, err = parse_phc(encoded)
    if not parsed then return false, err end
    if parsed.variant ~= "i" then
      return false, "pure tier only supports Argon2i; install libargon2 for Argon2id/Argon2d"
    end
    if not parsed.hash then return false, "no hash in encoded string" end
    local opts = { variant = parsed.variant, t = parsed.t, m = parsed.m, p = parsed.p,
                   hash_len = #parsed.hash }
    local computed, herr = M.hash(password, parsed.salt, opts)
    if not computed then return false, herr end
    return ct_eq(parsed.hash, computed)
  end

  function M.verify_raw(derived, password, salt, opts)
    if type(derived) ~= "string" then return nil, "derived must be a string" end
    local computed, err = M.hash(password, salt, opts)
    if not computed then return nil, err end
    return ct_eq(derived, computed)
  end
end

return M
