if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ========================
-- BASIC RLE
-- ========================

-- Encode a binary string with RLE.
-- Format: each run is (count_byte, data_byte).
-- Runs longer than 255 are split into multiple (count, byte) pairs.
--: (string) -> string
function M.encode(s)
  local out = {}
  local n = #s
  local i = 1
  while i <= n do
    local c = s:sub(i, i)
    local j = i + 1
    while j <= n and s:sub(j, j) == c do j = j + 1 end
    local run = j - i
    while run > 0 do
      local chunk = math.min(run, 255)
      out[#out + 1] = string.char(chunk)
      out[#out + 1] = c
      run = run - chunk
    end
    i = j
  end
  return table.concat(out)
end

-- Decode RLE back to original string.
--: (string) -> (string | nil, string | nil)
function M.decode(encoded)
  if #encoded % 2 ~= 0 then
    return nil, "invalid rle: odd number of bytes"
  end
  local out = {}
  local n = #encoded
  local i = 1
  while i <= n do
    local count = encoded:byte(i) --[[:! integer]]
    local byte  = encoded:sub(i + 1, i + 1)
    if count == 0 then
      return nil, "invalid rle: zero-count run at byte " .. i
    end
    out[#out + 1] = string.rep(byte, count)
    i = i + 2
  end
  return table.concat(out)
end

-- ========================
-- PCX-STYLE RLE
-- ========================
-- Runs of length >= min_run are encoded as (control_byte | count, data_byte).
-- Literal bytes that match control_byte are escaped as (control_byte | 1, byte).
-- Bytes not part of a run and not equal to control_byte are passed through.
--
-- Default opts: { min_run = 3, control_byte = 0xC0 }

local DEFAULT_PCX_MIN_RUN    = 3
local DEFAULT_PCX_CONTROL    = 0xC0
local PCX_COUNT_MASK         = 0x3F  -- low 6 bits of control word hold count (1..63)
local PCX_MAX_RUN            = 63

--: (string, { min_run?: integer, control_byte?: integer, ... } | nil) -> string
function M.encode_pcx(s, opts)
  local min_run      = ((opts and opts.min_run)      or DEFAULT_PCX_MIN_RUN)  --[[:! integer]]
  local control_byte = ((opts and opts.control_byte) or DEFAULT_PCX_CONTROL) --[[:! integer]]
  local control_hi   = control_byte  -- upper bits that mark a control word
  -- We check if a byte >= control_byte to detect control bytes.
  -- The top two bits of control_byte must be set (i.e. 0xC0) for classic PCX.
  local out = {}
  local n = #s
  local i = 1
  while i <= n do
    local c    = s:byte(i) --[[:! integer]]
    local j    = i + 1
    while j <= n and s:byte(j) == c do j = j + 1 end
    local run  = j - i
    if run >= min_run then
      -- Encode as run(s)
      while run > 0 do
        local chunk = math.min(run, PCX_MAX_RUN)
        out[#out + 1] = string.char(control_hi + chunk)
        out[#out + 1] = string.char(c)
        run = run - chunk
      end
    else
      -- Literal(s): escape any byte >= control_byte
      for k = i, j - 1 do
        local b = s:byte(k) --[[:! integer]]
        if b >= control_byte then
          -- Escape: emit (control_byte | 1, b)
          out[#out + 1] = string.char(control_hi + 1)
          out[#out + 1] = string.char(b)
        else
          out[#out + 1] = string.char(b)
        end
      end
    end
    i = j
  end
  return table.concat(out)
end

--: (string, { control_byte?: integer, ... } | nil) -> (string | nil, string | nil)
function M.decode_pcx(encoded, opts)
  local control_byte = ((opts and opts.control_byte) or DEFAULT_PCX_CONTROL) --[[:! integer]]
  local out = {}
  local n   = #encoded
  local i   = 1
  while i <= n do
    local b = encoded:byte(i) --[[:! integer]]
    if b >= control_byte then
      -- Control word: next byte is the data
      if i + 1 > n then
        return nil, "invalid pcx: control byte at end of stream"
      end
      local count = b - control_byte  -- number of repeats (1..63)
      local data  = encoded:sub(i + 1, i + 1)
      out[#out + 1] = string.rep(data, count)
      i = i + 2
    else
      -- Literal byte
      out[#out + 1] = string.char(b)
      i = i + 1
    end
  end
  return table.concat(out)
end

-- ========================
-- BURROWS-WHEELER TRANSFORM
-- ========================

-- BWT: permute string so runs are concentrated.
-- Returns: transformed string, index (1-based position of original string in sorted rotations).
-- O(n^2) naive — suitable for short strings.
--: (string) -> (string, integer)
function M.bwt(s)
  local n = #s
  if n == 0 then return "", 1 end

  -- Store rotation start indices (1-based), sort lexicographically.
  local rot = {}  --: { [integer]: integer }
  for i = 1, n do rot[i] = i end
  table.sort(rot, function(ai, bi)
    local av = ai --[[:! integer]]
    local bv = bi --[[:! integer]]
    for k = 0, n - 1 do
      local pa = (av - 1 + k) % n + 1 --[[:! integer]]
      local pb = (bv - 1 + k) % n + 1 --[[:! integer]]
      local ca = s:byte(pa) --[[:! integer]]
      local cb = s:byte(pb) --[[:! integer]]
      if ca < cb then return true end
      if ca > cb then return false end
    end
    return false
  end)

  -- Last column: the character just before each rotation start (wrapping).
  local last  = {}
  local index = 1
  for i, start in ipairs(rot) do
    local off = (start - 2) % n + 1 --[[:! integer]]
    last[i] = s:sub(off, off)
    if start == 1 then index = i end
  end
  return table.concat(last), index
end

-- Inverse BWT (O(n) algorithm).
--: (string, integer) -> string
function M.ibwt(t, index)
  local n = #t
  if n == 0 then return "" end

  -- L = last column = t
  -- Build next[] array using the standard rank-based method.
  local count = {}  --: { [integer]: integer }
  for i = 0, 255 do count[i] = 0 end
  local L_bytes = {}  --: { [integer]: integer }
  for i = 1, n do
    local b = t:byte(i) --[[:! integer]]
    L_bytes[i] = b
    count[b] = count[b] + 1
  end

  -- Cumulative sum to get starting position of each character in sorted F.
  local starts = {}  --: { [integer]: integer }
  local total  = 0  --: integer
  for i = 0, 255 do
    starts[i] = total
    total = total + count[i]
  end

  -- rank[i] = how many times L_bytes[i] appeared in L[1..i-1]
  -- next[i] = the row in the sorted rotation matrix whose last char is L[i]
  --         = starts[L[i]] + rank[i]
  local seen  = {}  --: { [integer]: integer }
  for i = 0, 255 do seen[i] = 0 end
  local nxt = {}  --: { [integer]: integer }
  for i = 1, n do
    local b  = L_bytes[i]
    nxt[i]   = starts[b] + seen[b] + 1  -- 1-based
    seen[b]  = seen[b] + 1
  end

  -- Reconstruct original: walk nxt[] starting from index, n times.
  local out  = {}
  local row  = index
  for i = n, 1, -1 do
    out[i] = L_bytes[row]
    row    = nxt[row]
  end

  local chars = {}
  for i = 1, n do chars[i] = string.char(out[i]) end
  return table.concat(chars)
end

-- ========================
-- MOVE-TO-FRONT
-- ========================

-- MTF encode: returns array of 0-based indices.
--: (string) -> { [integer]: integer }
function M.mtf_encode(s)
  -- Initialise alphabet 0..255
  local alphabet = {}
  for i = 0, 255 do alphabet[i + 1] = i end  -- alphabet[1..256], value = byte

  local n      = #s
  local result = {}
  for i = 1, n do
    local b = s:byte(i)
    -- Find position of b in alphabet
    local pos
    for j = 1, 256 do
      if alphabet[j] == b then
        pos = j - 1  -- 0-based index
        -- Move to front
        table.remove(alphabet, j)
        table.insert(alphabet, 1, b)
        break
      end
    end
    result[i] = pos
  end
  return result
end

-- MTF decode: inverse of mtf_encode.
function M.mtf_decode(ints)
  local alphabet = {}
  for i = 0, 255 do alphabet[i + 1] = i end

  local n    = #ints
  local out  = {}
  for i = 1, n do
    local pos = ints[i] + 1  -- convert to 1-based
    local b   = alphabet[pos]
    out[i]    = string.char(b)
    -- Move to front
    table.remove(alphabet, pos)
    table.insert(alphabet, 1, b)
  end
  return table.concat(out)
end

-- ========================
-- COMBINED PIPELINE
-- ========================

-- Pack a 32-bit big-endian unsigned integer into 4 bytes.
local function pack_u32(n)
  return string.char(
    math.floor(n / 0x1000000) % 256,
    math.floor(n / 0x10000)   % 256,
    math.floor(n / 0x100)     % 256,
    n % 256
  )
end

-- Unpack a 32-bit big-endian unsigned integer from 4 bytes at position pos.
--: (string, integer) -> number
local function unpack_u32(s, pos)
  local a = s:byte(pos)     --[[:! integer]]
  local b = s:byte(pos + 1) --[[:! integer]]
  local c = s:byte(pos + 2) --[[:! integer]]
  local d = s:byte(pos + 3) --[[:! integer]]
  return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end

-- BWT + MTF + RLE pipeline (analogous to bzip2's core).
-- Compressed format: 4-byte big-endian BWT index, then RLE-encoded MTF stream.
function M.compress(s)
  if #s == 0 then
    return pack_u32(1) .. ""
  end
  -- Step 1: BWT
  local bwt_out, bwt_idx = M.bwt(s)
  -- Step 2: MTF encode
  local mtf_out = M.mtf_encode(bwt_out)
  -- Step 3: Convert MTF indices to bytes (each value is 0..255)
  local mtf_bytes = {}
  for i = 1, #mtf_out do
    mtf_bytes[i] = string.char(mtf_out[i])
  end
  local mtf_str = table.concat(mtf_bytes)
  -- Step 4: RLE encode
  local rle_out = M.encode(mtf_str)
  -- Step 5: Prepend BWT index as 4-byte big-endian
  return pack_u32(bwt_idx) .. rle_out
end

--: (string) -> (string | nil, string | nil)
function M.decompress(encoded)
  if #encoded < 4 then
    return nil, "invalid compressed data: too short"
  end
  local bwt_idx = unpack_u32(encoded, 1) --[[:! integer]]
  local rle_data = encoded:sub(5)
  -- Step 1: RLE decode
  local mtf_str, err = M.decode(rle_data)
  if not mtf_str then
    return nil, "decompress: rle decode failed: " .. (err or "")
  end
  -- Step 2: Convert bytes back to MTF index array
  local mtf_ints = {}
  for i = 1, #mtf_str do
    mtf_ints[i] = mtf_str:byte(i)
  end
  -- Step 3: MTF decode
  local bwt_out = M.mtf_decode(mtf_ints)
  -- Step 4: Inverse BWT
  local original = M.ibwt(bwt_out, bwt_idx)
  return original
end

-- ========================
-- DELTA ENCODING
-- ========================

-- Delta encode an array of numbers.
-- First value is stored as-is; subsequent values store difference from previous.
function M.delta_encode(values)
  local n      = #values
  local result = {}
  if n == 0 then return result end
  result[1] = values[1]
  for i = 2, n do
    result[i] = values[i] - values[i - 1]
  end
  return result
end

-- Delta decode: inverse of delta_encode.
function M.delta_decode(deltas)
  local n      = #deltas
  local result = {}
  if n == 0 then return result end
  result[1] = deltas[1]
  for i = 2, n do
    result[i] = result[i - 1] + deltas[i]
  end
  return result
end

-- Delta encode a binary string (byte-wise differences, wrapping mod 256).
function M.delta_encode_bytes(s)
  local n   = #s
  local out = {}
  if n == 0 then return "" end
  out[1] = s:byte(1)
  for i = 2, n do
    out[i] = (s:byte(i) - s:byte(i - 1)) % 256
  end
  local chars = {}
  for i = 1, n do chars[i] = string.char(out[i]) end
  return table.concat(chars)
end

-- Delta decode bytes: inverse of delta_encode_bytes.
function M.delta_decode_bytes(s)
  local n   = #s
  local out = {}
  if n == 0 then return "" end
  out[1] = s:byte(1)
  for i = 2, n do
    out[i] = (out[i - 1] + s:byte(i)) % 256
  end
  local chars = {}
  for i = 1, n do chars[i] = string.char(out[i]) end
  return table.concat(chars)
end

return M
