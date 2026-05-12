-- lib/compress/pure.lua
-- Pure Lua INFLATE (RFC 1951 DEFLATE decompression).
-- Supports zlib (RFC 1950), gzip (RFC 1952), and raw DEFLATE formats.
-- No deflate/compress — that requires system zlib.

local byte = string.byte
local sub = string.sub
local char = string.char
local concat = table.concat
-- Helper: extract a single byte as integer
--: (string, integer) -> integer
local function byte1(s, i) return (byte(s, i) or 0) end

local _bit = (pcall(require, "bit") and require("bit") or nil)
local band = (_bit and _bit.band or function(a, b) return a % (b + 1) end) --[[:! (integer, integer) -> integer]]
local rshift = (_bit and _bit.rshift or function(a, n) return math.floor(a / 2^n) end) --[[:! (integer, integer) -> integer]]
local bxor = (_bit and _bit.bxor or function(a, b) return 0 end) --[[:! (integer, integer) -> integer]]
local lshift = (_bit and _bit.lshift or function(a, n) return math.floor(a * 2^n) end) --[[:! (integer, integer) -> integer]]

-- Convert a signed 32-bit integer (as returned by bit.*) to unsigned Lua number.
--: (number) -> number
local function to_u32(n)
  if n < 0 then return n + 4294967296 end
  return n
end

-- ── Adler-32 ─────────────────────────────────────────────────────────────────

local MOD_ADLER = 65521

--: (string) -> number
local function adler32(data)
  local a, b = 1, 0
  for i = 1, #data do
    a = (a + byte1(data, i)) % MOD_ADLER
    b = (b + a) % MOD_ADLER
  end
  return b * 65536 + a
end

-- ── CRC-32 ───────────────────────────────────────────────────────────────────

local crc_table
do
  crc_table = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if band(c, 1) == 1 then
        c = bxor(rshift(c, 1), math.floor(0xEDB88320))
      else
        c = rshift(c, 1)
      end
    end
    crc_table[i] = c
  end
end

--: (string) -> number
local function crc32(data)
  local c = math.floor(0xFFFFFFFF) --[[:! integer]]
  for i = 1, #data do
    local idx = band(bxor(c, byte1(data, i)), 0xFF)
    c = bxor(rshift(c, 8), (crc_table[idx] or 0) --[[:! integer]])
  end
  return to_u32(band(bxor(c, math.floor(0xFFFFFFFF)), math.floor(0xFFFFFFFF)))
end

-- ── Bit reader ───────────────────────────────────────────────────────────────

--:: bit_reader = { data: string, pos: integer, bitbuf: number, bitcnt: integer }
--:: huffman_tree = { minbits: integer, maxbits: integer, [integer]: integer }
--:: inflate_opts = { format: string | nil }
--:: inflater_handle = { push: (string) -> ((boolean | nil), (string | nil)), finish: () -> ((string | nil), (string | nil)) }

local function make_reader(data, pos)
  return {
    data = data,
    pos = pos,        -- byte position (1-indexed)
    bitbuf = 0,       -- accumulated bits
    bitcnt = 0,       -- number of bits in bitbuf
  }
end

--: (bit_reader, integer) -> number
local function read_bits(r, n)
  while r.bitcnt < n do
    if r.pos > #r.data then
      error("unexpected end of input")
    end
    r.bitbuf = r.bitbuf + byte1(r.data, r.pos) * (2 ^ r.bitcnt)
    r.pos = r.pos + 1
    r.bitcnt = r.bitcnt + 8
  end
  local mask = 2 ^ n - 1
  local val = r.bitbuf % (mask + 1)
  r.bitbuf = math.floor(r.bitbuf / (2 ^ n))
  r.bitcnt = r.bitcnt - n
  return val
end

-- Discard remaining bits in current byte (align to byte boundary)
--: (bit_reader) -> nil
local function align_byte(r)
  r.bitbuf = 0
  r.bitcnt = 0
end

-- Read bytes directly (after byte alignment)
--: (bit_reader, integer) -> string
local function read_bytes(r, n)
  align_byte(r)
  if r.pos + n - 1 > #r.data then
    error("unexpected end of input")
  end
  local s = sub(r.data, r.pos, r.pos + n - 1)
  r.pos = r.pos + n
  return s
end

-- ── Huffman tree builder ─────────────────────────────────────────────────────

-- Build a Huffman decode table from code lengths.
-- Returns a table: { minbits, maxbits, [code] = symbol }
-- where code is the bit-reversed prefix of the appropriate length.
--: (number[], integer) -> huffman_tree
local function build_tree(lengths, nsym)
  local maxbits = 0 --: integer
  local bl_count = {} --: { [integer]: integer }
  for i = 0, nsym - 1 do
    local len = (lengths[i] or 0) --[[:! integer]]
    if len > 0 then
      bl_count[len] = (bl_count[len] or 0) + 1
      if len > maxbits then maxbits = len end
    end
  end
  if maxbits == 0 then
    local empty_tree = { minbits = 1, maxbits = 1 } --[[:! huffman_tree]]
    return empty_tree
  end

  -- Compute next_code for each bit length
  local next_code = {} --: { [integer]: integer }
  local code = 0 --: integer
  for bits = 1, maxbits do
    code = (code + (bl_count[bits - 1] or 0)) * 2
    next_code[bits] = code
  end

  -- Assign codes and store bit-reversed in lookup table
  local tree = { minbits = maxbits, maxbits = maxbits } --[[:! huffman_tree]]
  for i = 0, nsym - 1 do
    local len = (lengths[i] or 0) --[[:! integer]]
    if len > 0 then
      local c = (next_code[len] or 0) --: integer
      next_code[len] = c + 1
      -- Bit-reverse the code
      local rev = 0 --: integer
      local tmp = c --: integer
      for _ = 1, len do
        rev = rev * 2 + tmp % 2
        tmp = math.floor(tmp / 2) --[[:! integer]]
      end
      -- Store with length encoded
      tree[rev * 32 + len] = i
      if len < tree.minbits then tree.minbits = len end
    end
  end
  return tree
end

-- Decode one symbol from the bit stream using the Huffman tree.
-- The tree stores bit-reversed codes (see build_tree), so we accumulate bits
-- LSB-first: each new bit goes into the next higher position.
--: (bit_reader, huffman_tree) -> number
local function decode_symbol(r, tree)
  local code = 0
  local mask = 1
  for len = 1, tree.maxbits do
    if read_bits(r, 1) == 1 then
      code = code + mask
    end
    mask = mask * 2
    local sym = tree[code * 32 + len]
    if sym then return sym end
  end
  error("invalid Huffman code")
end

-- ── Fixed Huffman tables (RFC 1951 §3.2.6) ──────────────────────────────────

local fixed_lit_tree, fixed_dist_tree
do
  local lengths = {}
  for i = 0, 143 do lengths[i] = 8 end
  for i = 144, 255 do lengths[i] = 9 end
  for i = 256, 279 do lengths[i] = 7 end
  for i = 280, 287 do lengths[i] = 8 end
  fixed_lit_tree = build_tree(lengths, 288)

  local dlengths = {}
  for i = 0, 31 do dlengths[i] = 5 end
  fixed_dist_tree = build_tree(dlengths, 32)
end

-- ── Length and distance extra bits (RFC 1951 §3.2.5) ─────────────────────────

local len_base = {
  [257]=3,[258]=4,[259]=5,[260]=6,[261]=7,[262]=8,[263]=9,[264]=10,
  [265]=11,[266]=13,[267]=15,[268]=17,[269]=19,[270]=23,[271]=27,[272]=31,
  [273]=35,[274]=43,[275]=51,[276]=59,[277]=67,[278]=83,[279]=99,[280]=115,
  [281]=131,[282]=163,[283]=195,[284]=227,[285]=258,
}
local len_extra = {
  [257]=0,[258]=0,[259]=0,[260]=0,[261]=0,[262]=0,[263]=0,[264]=0,
  [265]=1,[266]=1,[267]=1,[268]=1,[269]=2,[270]=2,[271]=2,[272]=2,
  [273]=3,[274]=3,[275]=3,[276]=3,[277]=4,[278]=4,[279]=4,[280]=4,
  [281]=5,[282]=5,[283]=5,[284]=5,[285]=0,
}
local dist_base = {
  [0]=1,[1]=2,[2]=3,[3]=4,[4]=5,[5]=7,[6]=9,[7]=13,
  [8]=17,[9]=25,[10]=33,[11]=49,[12]=65,[13]=97,[14]=129,[15]=193,
  [16]=257,[17]=385,[18]=513,[19]=769,[20]=1025,[21]=1537,[22]=2049,[23]=3073,
  [24]=4097,[25]=6145,[26]=8193,[27]=12289,[28]=16385,[29]=24577,
}
local dist_extra = {
  [0]=0,[1]=0,[2]=0,[3]=0,[4]=1,[5]=1,[6]=2,[7]=2,
  [8]=3,[9]=3,[10]=4,[11]=4,[12]=5,[13]=5,[14]=6,[15]=6,
  [16]=7,[17]=7,[18]=8,[19]=8,[20]=9,[21]=9,[22]=10,[23]=10,
  [24]=11,[25]=11,[26]=12,[27]=12,[28]=13,[29]=13,
}

-- ── DEFLATE block decompression ──────────────────────────────────────────────

-- Decompress blocks into output table. r = bit reader, out = output table.
--: (bit_reader, string[]) -> nil
local function inflate_blocks(r, out)
  local out_n = #out
  -- Maintain a flat string window for back-references
  local window = {}
  local win_n = 0

  local function emit(b)
    out_n = out_n + 1
    out[out_n] = b
    win_n = win_n + 1
    window[win_n] = b
  end

  local bfinal
  repeat
    bfinal = read_bits(r, 1)
    local btype = read_bits(r, 2)

    if btype == 0 then
      -- Stored block
      align_byte(r)
      if r.pos + 3 > #r.data then error("unexpected end of input") end
      local len = byte1(r.data, r.pos) + byte1(r.data, r.pos + 1) * 256
      local nlen = byte1(r.data, r.pos + 2) + byte1(r.data, r.pos + 3) * 256
      r.pos = r.pos + 4
      if band(len + nlen, 0xFFFF) ~= 0xFFFF then
        error("invalid stored block length")
      end
      if r.pos + len - 1 > #r.data then error("unexpected end of input") end
      for i = 0, len - 1 do
        emit(char(byte1(r.data, r.pos + i)))
      end
      r.pos = r.pos + len

    elseif btype == 1 or btype == 2 then
      -- Compressed block
      local lit_tree, dist_tree
      if btype == 1 then
        lit_tree = fixed_lit_tree
        dist_tree = fixed_dist_tree
      else
        -- Dynamic Huffman codes
        local hlit = math.floor(read_bits(r, 5) + 257) --[[:! integer]]
        local hdist = math.floor(read_bits(r, 5) + 1) --[[:! integer]]
        local hclen = math.floor(read_bits(r, 4) + 4) --[[:! integer]]

        local cl_order = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}
        local cl_lengths = {}
        for i = 1, hclen do
          cl_lengths[cl_order[i]] = read_bits(r, 3)
        end
        local cl_tree = build_tree(cl_lengths, 19)

        -- Decode literal/length + distance code lengths
        local lengths = {}
        local total = hlit + hdist
        local i = 0
        while i < total do
          local sym = decode_symbol(r, cl_tree)
          if sym < 16 then
            lengths[i] = sym
            i = i + 1
          elseif sym == 16 then
            local rep = read_bits(r, 2) + 3
            local prev = lengths[i - 1] or 0
            for _ = 1, rep do
              lengths[i] = prev
              i = i + 1
            end
          elseif sym == 17 then
            local rep = read_bits(r, 3) + 3
            for _ = 1, rep do
              lengths[i] = 0
              i = i + 1
            end
          elseif sym == 18 then
            local rep = read_bits(r, 7) + 11
            for _ = 1, rep do
              lengths[i] = 0
              i = i + 1
            end
          end
        end

        -- Split into literal/length and distance code lengths
        local lit_lengths = {}
        for j = 0, hlit - 1 do lit_lengths[j] = lengths[j] or 0 end
        local dist_lengths = {}
        for j = 0, hdist - 1 do dist_lengths[j] = lengths[hlit + j] or 0 end

        lit_tree = build_tree(lit_lengths, hlit)
        dist_tree = build_tree(dist_lengths, hdist)
      end

      -- Decode symbols
      while true do
        local sym = decode_symbol(r, lit_tree)
        if sym < 256 then
          emit(char(sym))
        elseif sym == 256 then
          break -- end of block
        else
          -- Length
          local length = len_base[sym] + read_bits(r, len_extra[sym])
          -- Distance
          local dsym = decode_symbol(r, dist_tree)
          local distance = dist_base[dsym] + read_bits(r, dist_extra[dsym])
          -- Copy from window (handle overlapping copies)
          local src_start = win_n - distance
          for j = 0, length - 1 do
            local src_idx = src_start + (j % distance) + 1
            emit(window[src_idx])
          end
        end
      end
    else
      error("invalid block type: " .. btype)
    end
  until bfinal == 1
end

-- ── Format parsing ───────────────────────────────────────────────────────────

--: (string, (inflate_opts | nil)) -> ((string | nil), (string | nil))
local function inflate(input, opts)
  local opts_ = (opts or {}) --[[:! inflate_opts]]
  local format = opts_.format or "zlib"
  local pos = 1 --: integer

  if format == "zlib" then
    -- Parse zlib header (RFC 1950)
    if #input < 6 then return nil, "input too short for zlib format" end
    local cmf = byte1(input, 1)
    local flg = byte1(input, 2)
    if (cmf * 256 + flg) % 31 ~= 0 then
      return nil, "invalid zlib header checksum"
    end
    local cm = cmf % 16
    if cm ~= 8 then return nil, "unsupported compression method: " .. cm end
    pos = 3
    local fdict = math.floor(flg / 32) % 2
    if fdict == 1 then
      if #input < 6 then return nil, "input too short for zlib with dict" end
      pos = 7 -- skip 4-byte DICTID
    end

    -- Decompress
    local out = {}
    local ok2, err = pcall(inflate_blocks, make_reader(input, pos), out)
    if not ok2 then return nil, err end
    local result = concat(out)

    -- Verify Adler-32 (last 4 bytes, big-endian)
    local alen = #input
    if alen < pos + 3 then return nil, "missing adler32 checksum" end
    local expected = byte1(input, alen - 3) * 16777216 +
                     byte1(input, alen - 2) * 65536 +
                     byte1(input, alen - 1) * 256 +
                     byte1(input, alen)
    local actual = adler32(result)
    if expected ~= actual then
      return nil, "adler32 checksum mismatch: expected " .. expected .. " got " .. actual
    end
    return result

  elseif format == "gzip" then
    -- Parse gzip header (RFC 1952)
    if #input < 18 then return nil, "input too short for gzip format" end
    if byte1(input, 1) ~= 0x1f or byte1(input, 2) ~= 0x8b then
      return nil, "invalid gzip magic number"
    end
    if byte1(input, 3) ~= 8 then
      return nil, "unsupported gzip compression method"
    end
    local flg = byte1(input, 4)
    pos = 11 -- skip ID1, ID2, CM, FLG, MTIME(4), XFL, OS

    -- FEXTRA
    if band(flg, 4) ~= 0 then
      if pos + 1 > #input then return nil, "truncated gzip header (FEXTRA)" end
      local xlen = byte1(input, pos) + byte1(input, pos + 1) * 256
      pos = pos + 2 + xlen
    end
    -- FNAME
    if band(flg, 8) ~= 0 then
      while pos <= #input and byte1(input, pos) ~= 0 do pos = pos + 1 end
      pos = pos + 1 -- skip null terminator
    end
    -- FCOMMENT
    if band(flg, 16) ~= 0 then
      while pos <= #input and byte1(input, pos) ~= 0 do pos = pos + 1 end
      pos = pos + 1
    end
    -- FHCRC
    if band(flg, 2) ~= 0 then
      pos = pos + 2
    end

    if pos > #input then return nil, "truncated gzip header" end

    -- Decompress
    local out = {}
    local reader = make_reader(input, pos)
    local ok2, err = pcall(inflate_blocks, reader, out)
    if not ok2 then return nil, err end
    local result = concat(out)

    -- After decompression, align and read CRC32 + ISIZE (last 8 bytes)
    -- The trailer is at the end of the input, after the compressed data
    local alen = #input
    if alen < 8 then return nil, "missing gzip trailer" end
    local expected_crc = byte1(input, alen - 7) +
                         byte1(input, alen - 6) * 256 +
                         byte1(input, alen - 5) * 65536 +
                         byte1(input, alen - 4) * 16777216
    local expected_size = byte1(input, alen - 3) +
                          byte1(input, alen - 2) * 256 +
                          byte1(input, alen - 1) * 65536 +
                          byte1(input, alen) * 16777216

    local actual_crc = crc32(result)
    if expected_crc ~= actual_crc then
      return nil, "crc32 checksum mismatch"
    end
    local actual_size = #result % 4294967296
    if expected_size ~= actual_size then
      return nil, "gzip size mismatch"
    end
    return result

  elseif format == "raw" then
    -- Raw DEFLATE (no header, no checksum)
    local out = {}
    local ok2, err = pcall(inflate_blocks, make_reader(input, pos), out)
    if not ok2 then return nil, err end
    return concat(out)

  else
    return nil, "unknown format: " .. tostring(format)
  end
end

-- ── Streaming inflater ───────────────────────────────────────────────────────

--: ((inflate_opts | nil)) -> inflater_handle
local function inflater(opts)
  local chunks = {}
  return {
    --: (string) -> ((boolean | nil), (string | nil))
    push = function(chunk)
      chunks[#chunks + 1] = chunk
      return true
    end,
    --: () -> ((string | nil), (string | nil))
    finish = function()
      local full = concat(chunks)
      return inflate(full, opts)
    end,
  }
end

-- ── Module ───────────────────────────────────────────────────────────────────

local M = {}

--: (string, (inflate_opts | nil)) -> (nil, string)
M.deflate = function(_, _)
  return nil, "deflate not available in pure-lua tier"
end

M.inflate = inflate
M.encode = M.deflate
M.decode = inflate
M.deflater = function(_)
  return nil, "deflate not available in pure-lua tier"
end
M.inflater = inflater
M._tier = "pure-lua"

-- Expose checksum functions for testing
M.adler32 = adler32
M.crc32 = crc32

return M
