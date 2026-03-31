if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")
local bit = require("bit")

pcall(ffi.cdef, [[
  int open(const char *pathname, int flags);
  ssize_t read(int fd, void *buf, size_t count);
  int close(int fd);
  long syscall(long number, ...);
  char *strerror(int errnum);
]])

-- getrandom(2) syscall number: 318 on x86_64, 384 on aarch64
local SYS_getrandom
if ffi.arch == "x64" then
  SYS_getrandom = 318
elseif ffi.arch == "arm64" then
  SYS_getrandom = 278
end

local O_RDONLY = 0

local mod = {}

-- Reusable buffers
local buf8 = ffi.new("uint8_t[8]")
local buf4 = ffi.new("uint8_t[4]")

-- Try getrandom(2) syscall first, fall back to /dev/urandom
local _read_random
do
  local has_getrandom = false
  if SYS_getrandom then
    -- Probe: try reading 1 byte
    local probe = ffi.new("uint8_t[1]")
    local ret = ffi.C.syscall(ffi.cast("long", SYS_getrandom),
      ffi.cast("void*", probe), ffi.cast("size_t", 1), ffi.cast("long", 0))
    if ret == 1 then has_getrandom = true end
  end

  if has_getrandom then
    _read_random = function(dst, n)
      local total = 0
      while total < n do
        local ret = ffi.C.syscall(ffi.cast("long", SYS_getrandom),
          ffi.cast("void*", dst + total),
          ffi.cast("size_t", n - total),
          ffi.cast("long", 0))
        if ret < 0 then return nil, "getrandom() failed" end
        total = total + tonumber(ret)
      end
      return true
    end
  else
    -- /dev/urandom fallback
    local urandom_fd
    local function get_fd()
      if urandom_fd then return urandom_fd end
      local fd = ffi.C.open("/dev/urandom", O_RDONLY)
      if fd < 0 then return nil end
      urandom_fd = fd
      return fd
    end
    _read_random = function(dst, n)
      local fd = get_fd()
      if not fd then return nil, "failed to open /dev/urandom" end
      local total = 0
      while total < n do
        local ret = ffi.C.read(fd, dst + total, n - total)
        if ret <= 0 then return nil, "read from /dev/urandom failed" end
        total = total + tonumber(ret)
      end
      return true
    end
  end
end

--- Return n random bytes as a string.
--: fun(n: integer): string | nil, string | nil
function mod.bytes(n)
  if n <= 0 then return "" end
  local dst = ffi.new("uint8_t[?]", n)
  local ok, err = _read_random(dst, n)
  if not ok then return nil, err end
  return ffi.string(dst, n)
end

--- Return a random uint32.
--: fun(): integer | nil, string | nil
function mod.u32()
  local ok, err = _read_random(buf4, 4)
  if not ok then return nil, err end
  -- little-endian read
  return buf4[0] + buf4[1] * 0x100 + buf4[2] * 0x10000 + buf4[3] * 0x1000000
end

--- Return a random uint64 as a number.
--- Note: Lua numbers are doubles (53-bit mantissa), so values above 2^53 lose precision.
--: fun(): number | nil, string | nil
function mod.u64()
  local ok, err = _read_random(buf8, 8)
  if not ok then return nil, err end
  local lo = buf8[0] + buf8[1] * 0x100 + buf8[2] * 0x10000 + buf8[3] * 0x1000000
  local hi = buf8[4] + buf8[5] * 0x100 + buf8[6] * 0x10000 + buf8[7] * 0x1000000
  return lo + hi * 4294967296
end

--- Return a random integer in [min, max] inclusive, uniform (rejection sampling).
--: fun(min: integer, max: integer): integer | nil, string | nil
function mod.int(min, max)
  if min > max then return nil, "min > max" end
  if min == max then return min end
  local range = max - min -- [0, range]
  if range < 0 then
    -- overflow for very large ranges; fall back to u64-based
    local v, err = mod.u64()
    if not v then return nil, err end
    return min + math.floor(v % (range + 1))
  end
  -- Rejection sampling to avoid modulo bias
  -- Find smallest power of 2 >= (range + 1)
  if range <= 0xFFFFFFFF then
    -- 32-bit path
    local range1 = range + 1
    local mask = range1
    -- Round up to next power of 2 minus 1
    mask = bit.bor(mask, bit.rshift(mask, 1))
    mask = bit.bor(mask, bit.rshift(mask, 2))
    mask = bit.bor(mask, bit.rshift(mask, 4))
    mask = bit.bor(mask, bit.rshift(mask, 8))
    mask = bit.bor(mask, bit.rshift(mask, 16))
    -- mask is now 2^ceil(log2(range1)) - 1, all bits set
    -- Convert from signed to unsigned if needed
    local umask = mask < 0 and (mask + 4294967296) or mask
    while true do
      local ok, err = _read_random(buf4, 4)
      if not ok then return nil, err end
      local v = buf4[0] + buf4[1] * 0x100 + buf4[2] * 0x10000 + buf4[3] * 0x1000000
      v = v % (umask + 1)
      if v <= range then return min + v end
    end
  else
    -- Large range (>32-bit), use u64
    while true do
      local v, err = mod.u64()
      if not v then return nil, err end
      v = v % (range + 1)
      if v <= range then return min + v end
    end
  end
end

--- Return a random float in [0, 1).
--- Uses 53 bits of randomness for full double precision.
--: fun(): number | nil, string | nil
function mod.float()
  local ok, err = _read_random(buf8, 7)
  if not ok then return nil, err end
  -- Use 53 bits: 32 from first 4 bytes, 21 from next 3
  local lo = buf8[0] + buf8[1] * 0x100 + buf8[2] * 0x10000 + buf8[3] * 0x1000000
  local hi = buf8[4] + buf8[5] * 0x100 + bit.band(buf8[6], 0x1F) * 0x10000
  -- (hi * 2^32 + lo) / 2^53
  return (hi * 4294967296 + lo) / 9007199254740992
end

--- Return a random element from an array.
--: fun(array: any[]): any | nil, string | nil
function mod.choice(array)
  local n = #array
  if n == 0 then return nil, "empty array" end
  if n == 1 then return array[1] end
  local idx, err = mod.int(1, n)
  if not idx then return nil, err end
  return array[idx]
end

--- Fisher-Yates shuffle in-place. Returns the array.
--: fun(array: any[]): any[] | nil, string | nil
function mod.shuffle(array)
  local n = #array
  for i = n, 2, -1 do
    local j, err = mod.int(1, i)
    if not j then return nil, err end
    array[i], array[j] = array[j], array[i]
  end
  return array
end

local hex_chars = "0123456789abcdef"

--- Return n random bytes as a hex string (2n characters).
--: fun(n: integer): string | nil, string | nil
function mod.hex(n)
  if n <= 0 then return "" end
  local dst = ffi.new("uint8_t[?]", n)
  local ok, err = _read_random(dst, n)
  if not ok then return nil, err end
  local out = {}
  for i = 0, n - 1 do
    local b = dst[i]
    local hi = bit.rshift(b, 4) + 1
    local lo = bit.band(b, 0x0F) + 1
    out[i * 2 + 1] = hex_chars:sub(hi, hi)
    out[i * 2 + 2] = hex_chars:sub(lo, lo)
  end
  return table.concat(out)
end

--- Return a UUID v4 string (xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx).
--: fun(): string | nil, string | nil
function mod.uuid()
  local dst = ffi.new("uint8_t[16]")
  local ok, err = _read_random(dst, 16)
  if not ok then return nil, err end
  -- Set version (4) in byte 6: high nibble = 0100
  dst[6] = bit.bor(bit.band(dst[6], 0x0F), 0x40)
  -- Set variant (10xx) in byte 8: high 2 bits = 10
  dst[8] = bit.bor(bit.band(dst[8], 0x3F), 0x80)

  local h = {}
  for i = 0, 15 do
    local b = dst[i]
    local hi = bit.rshift(b, 4) + 1
    local lo = bit.band(b, 0x0F) + 1
    h[#h + 1] = hex_chars:sub(hi, hi)
    h[#h + 1] = hex_chars:sub(lo, lo)
  end
  -- 8-4-4-4-12
  return h[1]..h[2]..h[3]..h[4]..h[5]..h[6]..h[7]..h[8].."-"..
    h[9]..h[10]..h[11]..h[12].."-"..
    h[13]..h[14]..h[15]..h[16].."-"..
    h[17]..h[18]..h[19]..h[20].."-"..
    h[21]..h[22]..h[23]..h[24]..h[25]..h[26]..h[27]..h[28]..h[29]..h[30]..h[31]..h[32]
end

return mod
