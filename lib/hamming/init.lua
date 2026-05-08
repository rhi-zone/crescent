-- lib/hamming/init.lua
-- Hamming error-correcting codes, parity, checksums, and related schemes.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local bit = require("bit")
local band, bxor, bor, lshift, rshift = bit.band, bit.bxor, bit.bor, bit.lshift, bit.rshift
local floor = math.floor

-- ========================
-- INTERNAL HELPERS
-- ========================

-- Returns number of parity bits r needed for k data bits.
-- Invariant: 2^r >= k + r + 1
local function required_parity_bits(k)
  local r = 0
  while lshift(1, r) < k + r + 1 do
    r = r + 1
  end
  return r
end

-- Returns true if n is a power of 2 (i.e. a parity-bit position)
local function is_power_of_2(n)
  return n > 0 and band(n, n - 1) == 0
end

-- ========================
-- HAMMING CODE
-- ========================

-- Encode k data bits with Hamming error correction.
-- Returns codeword as array of 0/1 integers (length n = k + r).
--: (integer[]) -> integer[]
function M.encode(data)
  local k = #data
  local r = required_parity_bits(k)
  local n = k + r
  local cw = {} --[[: integer[] ]]

  -- Place data bits in non-power-of-2 positions (1-indexed)
  local di = 1
  for i = 1, n do
    if is_power_of_2(i) then
      cw[i] = 0  -- placeholder
    else
      cw[i] = data[di]
      di = di + 1
    end
  end

  -- Compute parity bits
  for p = 0, r - 1 do
    local pos = lshift(1, p)  -- 2^p
    local parity = 0
    for i = 1, n do
      if band(i, pos) ~= 0 then
        parity = bxor(parity, cw[i])
      end
    end
    cw[pos] = parity
  end

  return cw
end

-- Compute the error syndrome of a codeword.
-- Returns error_position (1-indexed), or 0 if no error.
--: (integer[]) -> integer
function M.syndrome(codeword)
  local n = #codeword
  local r = 0
  while lshift(1, r) <= n do r = r + 1 end

  local s = 0
  for p = 0, r - 1 do
    local pos = lshift(1, p)
    local parity = 0
    for i = 1, n do
      if band(i, pos) ~= 0 then
        parity = bxor(parity, codeword[i])
      end
    end
    if parity ~= 0 then
      s = bor(s, pos)
    end
  end
  return s
end

-- Decode and correct a received codeword.
-- Returns: data (array of data bits), errors_corrected (0 or 1), err
--: (integer[]) -> (integer[], integer)
function M.decode(codeword)
  local n = #codeword
  -- Make a mutable copy
  local cw = {}
  for i = 1, n do cw[i] = codeword[i] end

  local s = M.syndrome(cw)
  local errors_corrected = 0

  if s ~= 0 and s <= n then
    -- Flip the erroneous bit
    cw[s] = bxor(cw[s], 1)
    errors_corrected = 1
  end

  -- Extract data bits (non-power-of-2 positions)
  local data = {}
  for i = 1, n do
    if not is_power_of_2(i) then
      data[#data + 1] = cw[i]
    end
  end

  return data, errors_corrected
end

-- ========================
-- SECDED (Single Error Correct, Double Error Detect)
-- ========================

-- Encode with SECDED: adds one extra overall parity bit at position 0
-- (stored as the last element beyond the Hamming codeword, index n+1).
--: (integer[]) -> integer[]
function M.encode_secded(data)
  local cw = M.encode(data)
  -- Compute overall parity of all bits in cw
  local p = 0
  for i = 1, #cw do p = bxor(p, cw[i]) end
  cw[#cw + 1] = p
  return cw
end

-- Decode SECDED codeword.
-- Returns: data, single_corrected (bool), double_detected (bool)
--: (integer[]) -> (integer[], boolean, boolean)
function M.decode_secded(codeword)
  local n = #codeword
  -- Overall parity bit is the last element
  local overall_parity = codeword[n]

  -- Work on the Hamming portion (all but last element)
  local hamming_cw = {}
  for i = 1, n - 1 do hamming_cw[i] = codeword[i] end

  local s = M.syndrome(hamming_cw)

  -- Recalculate overall parity of the full received word
  local p = 0
  for i = 1, n do p = bxor(p, codeword[i]) end

  if s == 0 and p == 0 then
    -- No error
    local data, _ = M.decode(hamming_cw)
    return data, false, false
  elseif s ~= 0 and p ~= 0 then
    -- Single-bit error: syndrome points to error position, overall parity odd
    local cw = {} --[[: integer[] ]]
    for i = 1, n - 1 do cw[i] = hamming_cw[i] end
    if s <= n - 1 then
      cw[s] = bxor(cw[s], 1)
    end
    local data = {}
    for i = 1, n - 1 do
      if not is_power_of_2(i) then
        data[#data + 1] = cw[i]
      end
    end
    return data, true, false
  elseif s ~= 0 and p == 0 then
    -- Double-bit error: syndrome non-zero but overall parity even
    local data, _ = M.decode(hamming_cw)  -- best effort, data unreliable
    return data, false, true
  else
    -- s == 0, p ~= 0: error in the overall parity bit itself (single error)
    local data, _ = M.decode(hamming_cw)
    return data, true, false
  end
end

-- ========================
-- PARITY
-- ========================

-- Compute even parity bit for a sequence of bits (array of 0/1 or a byte).
-- Input: array of 0/1 integers, or a single integer (byte).
-- Returns 0 if even number of 1s (even parity), 1 if odd.
function M.parity_bit(data)
  if type(data) == "number" then
    -- Compute parity of a byte
    local v = band(data, 0xff)
    v = bxor(v, rshift(v, 4))
    v = bxor(v, rshift(v, 2))
    v = bxor(v, rshift(v, 1))
    return band(v, 1)
  end
  local p = 0
  for i = 1, #data do p = bxor(p, data[i]) end
  return p
end

-- Add a parity byte after each group of 7 data bytes (simple scheme).
-- The parity byte holds XOR of the preceding 7 bytes.
--: (string) -> string
function M.add_parity_bytes(s)
  local out = {}
  local len = #s
  local i = 1
  while i <= len do
    local chunk_end = math.min(i + 6, len)
    local xor_acc = 0
    for j = i, chunk_end do
      local b = string.byte(s, j)
      out[#out + 1] = string.char(b)
      xor_acc = bxor(xor_acc, b)
    end
    out[#out + 1] = string.char(xor_acc)
    i = chunk_end + 1
  end
  return table.concat(out)
end

-- Check parity of a string produced by add_parity_bytes.
-- Returns true if all parity bytes are correct.
--: (string) -> boolean
function M.check_parity_bytes(s)
  local len = #s
  -- Each group is up to 7 data bytes + 1 parity byte = up to 8 bytes
  local i = 1
  while i <= len do
    -- Find the parity byte: scan forward up to 8 bytes
    local group_size = math.min(8, len - i + 1)
    -- data bytes = group_size - 1, parity = last
    local xor_acc = 0
    for j = i, i + group_size - 2 do
      xor_acc = bxor(xor_acc, string.byte(s, j))
    end
    local parity_byte = string.byte(s, i + group_size - 1)
    if xor_acc ~= parity_byte then return false end
    i = i + group_size
  end
  return true
end

-- ========================
-- REPETITION CODE
-- ========================

-- Encode: repeat each bit n times.
-- data: array of 0/1; n: repetition count (odd for majority vote).
function M.repeat_encode(data, n)
  local out = {}
  for i = 1, #data do
    for _ = 1, n do
      out[#out + 1] = data[i]
    end
  end
  return out
end

-- Decode: majority vote over each group of n bits.
--: (integer[], integer) -> integer[]
function M.repeat_decode(encoded, n)
  local out = {}
  local len = #encoded
  local i = 1
  while i <= len do
    local ones = 0
    for j = i, math.min(i + n - 1, len) do
      ones = ones + encoded[j]
    end
    out[#out + 1] = (ones > n / 2) and 1 or 0
    i = i + n
  end
  return out
end

-- ========================
-- CHECKSUM
-- ========================

-- Internet checksum (RFC 1071): one's complement sum of 16-bit words.
-- data: string of bytes (even length; odd length padded with 0).
-- Returns 16-bit checksum as integer (ones' complement of the sum).
--: (string) -> integer
function M.inet_checksum(data)
  local sum = 0
  local len = #data
  local i = 1
  while i < len do
    local hi = string.byte(data, i) or 0
    local lo = string.byte(data, i + 1) or 0
    sum = sum + hi * 256 + lo
    i = i + 2
  end
  -- Pad if odd length
  if band(len, 1) == 1 then
    sum = sum + (string.byte(data, len) or 0) * 256
  end
  -- Fold 32-bit sum to 16 bits
  while sum > 0xffff do
    sum = band(sum, 0xffff) + rshift(sum, 16)
  end
  return bxor(sum, 0xffff)
end

-- Verify internet checksum: returns true if checksum over data (including
-- the checksum field) yields all-1s (0xffff after folding).
--: (string) -> boolean
function M.inet_verify(data)
  local sum = 0
  local len = #data
  local i = 1
  while i < len do
    local hi = string.byte(data, i) or 0
    local lo = string.byte(data, i + 1) or 0
    sum = sum + hi * 256 + lo
    i = i + 2
  end
  if band(len, 1) == 1 then
    sum = sum + (string.byte(data, len) or 0) * 256
  end
  while sum > 0xffff do
    sum = band(sum, 0xffff) + rshift(sum, 16)
  end
  return sum == 0xffff
end

-- Adler-32 checksum (used in zlib/PNG).
-- data: string; init: optional 32-bit initial value.
-- Returns 32-bit integer.
local MOD_ADLER = 65521
--: (string, integer | nil) -> integer
function M.adler32(data, init)
  local a = 1
  local b = 0
  if init then
    a = band(init, 0xffff)
    b = band(rshift(init, 16), 0xffff)
  end
  for i = 1, #data do
    a = (a + (string.byte(data, i) or 0)) % MOD_ADLER
    b = (b + a) % MOD_ADLER
  end
  return b * 65536 + a
end

-- Fletcher-16 checksum.
-- data: string. Returns 16-bit integer.
--: (string) -> integer
function M.fletcher16(data)
  local sum1 = 0
  local sum2 = 0
  for i = 1, #data do
    sum1 = (sum1 + (string.byte(data, i) or 0)) % 255
    sum2 = (sum2 + sum1) % 255
  end
  return sum2 * 256 + sum1
end

-- Fletcher-32 checksum.
-- data: string (treated as sequence of 16-bit words, little-endian;
-- odd trailing byte padded with 0). Returns 32-bit integer.
--: (string) -> integer
function M.fletcher32(data)
  local sum1 = 0
  local sum2 = 0
  local len = #data
  local i = 1
  while i <= len do
    local lo = string.byte(data, i) or 0
    local hi = (i < len) and (string.byte(data, i + 1) or 0) or 0
    local word = hi * 256 + lo
    sum1 = (sum1 + word) % 65535
    sum2 = (sum2 + sum1) % 65535
    i = i + 2
  end
  return sum2 * 65536 + sum1
end

-- ========================
-- LUHN ALGORITHM
-- ========================

-- Verify a Luhn check digit (credit card numbers, IMEI, etc.).
-- number_string: string of digits (including check digit).
-- Returns true if valid.
--: (string) -> boolean
function M.luhn_check(s)
  local sum = 0 --: number
  local alt = false
  for i = #s, 1, -1 do
    local d = tonumber(s:sub(i, i))
    if d == nil then return false end
    if alt then
      d = d * 2
      if d > 9 then d = d - 9 end
    end
    sum = sum + d
    alt = not alt
  end
  return sum % 10 == 0
end

-- Compute the Luhn check digit to append to a partial number string.
-- number_string: string of digits WITHOUT the check digit.
-- Returns the check digit (0–9) as an integer.
--: (string) -> integer
function M.luhn_digit(s)
  -- Append a dummy '0', compute what makes the sum divisible by 10
  local sum = 0 --: number
  local alt = true  -- position 1 from right (check digit position) is not doubled
  -- we iterate the partial number right-to-left (the check digit will be rightmost)
  for i = #s, 1, -1 do
    local d = tonumber(s:sub(i, i))
    if d == nil then d = 0 end
    if alt then
      d = d * 2
      if d > 9 then d = d - 9 end
    end
    sum = sum + d
    alt = not alt
  end
  local check = (10 - (sum % 10)) % 10
  return floor(check)
end

-- ========================
-- BIT MANIPULATION UTILITIES
-- ========================

-- Popcount: number of set bits in a 32-bit integer.
-- Note: LuaJIT's bit library uses signed 32-bit integers, so multiplication
-- overflow in the classic Hamming weight formula is avoided by using shifts.
function M.popcount(n)
  n = band(n, 0xffffffff)
  -- Count bits in pairs
  n = n - band(rshift(n, 1), 0x55555555)
  -- Count bits in nibbles
  n = band(n, 0x33333333) + band(rshift(n, 2), 0x33333333)
  -- Count bits in bytes
  n = band(n + rshift(n, 4), 0x0f0f0f0f)
  -- Sum bytes using shifts (avoids signed 32-bit multiplication overflow)
  n = n + rshift(n, 8)
  n = n + rshift(n, 16)
  return band(n, 0x3f)
end

-- Hamming distance between two integers (number of differing bits).
function M.hamming_distance(a, b)
  return M.popcount(bxor(a, b))
end

-- Minimum Hamming distance among all pairs in a set of codewords.
-- codewords: array of integers.
function M.min_distance(codewords)
  local min = math.huge
  for i = 1, #codewords do
    for j = i + 1, #codewords do
      local d = M.hamming_distance(codewords[i], codewords[j])
      if d < min then min = d end
    end
  end
  return min == math.huge and 0 or min
end

return M
