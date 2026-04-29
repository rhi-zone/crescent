-- lib/lz77/init.lua
-- Pure Lua LZ77 compression and decompression.
-- NOT DEFLATE — a simple standalone raw LZ77 with a custom binary frame format.
--
-- Public API:
--   M.compress(input, opts)   -> compressed, err
--   M.decompress(compressed)  -> decompressed, err
--   M.compressor(opts)        -> { write, finish }
--   M.decompressor()          -> { write, finish }
--   M._tier = "pure"
--
-- Format:
--   Header: "LZ77" (4 bytes) + window_bits (1 byte) + orig_len (4 bytes LE uint32)
--   Token stream:
--     0x00 bb          -- literal: raw byte bb
--     0x01 dd dd ll ll -- match: distance (2 bytes LE), length (2 bytes LE)
--     0xFF             -- end of stream

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local byte   = string.byte
local char   = string.char
local sub    = string.sub
local concat = table.concat

local M = {}
M._tier = "pure"

local MAGIC        = "LZ77"
local TOK_LITERAL  = 0x00
local TOK_MATCH    = 0x01
local TOK_END      = 0xFF
local MAX_CHAIN    = 32   -- max hash-chain candidates to check
local DEFAULT_WINDOW_BITS = 15
local DEFAULT_MIN_MATCH   = 3
local DEFAULT_MAX_MATCH   = 65535

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Encode a 32-bit unsigned integer as 4 little-endian bytes.
--: (number) -> string
local function le32(n)
  local b0 = n % 256; n = (n - b0) / 256
  local b1 = n % 256; n = (n - b1) / 256
  local b2 = n % 256; n = (n - b2) / 256
  local b3 = n % 256
  return char(b0, b1, b2, b3)
end

-- Decode a 32-bit unsigned integer from 4 little-endian bytes in s at pos.
--: (string, number) -> number
local function read_le32(s, pos)
  local b0, b1, b2, b3 = byte(s, pos, pos + 3)
  return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

-- Encode a 16-bit unsigned integer as 2 little-endian bytes.
--: (number) -> string
local function le16(n)
  local b0 = n % 256
  local b1 = (n - b0) / 256
  return char(b0, b1)
end

-- Decode a 16-bit unsigned integer from 2 little-endian bytes in s at pos.
--: (string, number) -> number
local function read_le16(s, pos)
  local b0, b1 = byte(s, pos, pos + 1)
  return b0 + b1 * 256
end

-- ── Compression ──────────────────────────────────────────────────────────────

-- Compute a 3-byte hash index into a table of size window_size.
-- Returns a key string for use in the hash table.
--: (string, number, number) -> number
local function hash3(s, pos, window_size)
  local b1, b2, b3 = byte(s, pos, pos + 2)
  return (b1 * 65536 + b2 * 256 + b3) % window_size
end

--: (string, ({ window_bits: (number | nil), min_match: (number | nil), max_match: (number | nil) } | nil)) -> ((string | nil), (string | nil))
local function compress(input, opts)
  opts = opts or {}
  local window_bits = opts.window_bits or DEFAULT_WINDOW_BITS
  local min_match   = opts.min_match   or DEFAULT_MIN_MATCH
  local max_match   = opts.max_match   or DEFAULT_MAX_MATCH

  if window_bits < 1 or window_bits > 15 then
    return nil, "window_bits must be 1-15"
  end
  if type(input) ~= "string" then
    return nil, "input must be a string"
  end

  local window_size = 2 ^ window_bits
  local input_len   = #input

  -- Build header
  local header = MAGIC .. char(window_bits) .. le32(input_len)

  -- Hash table: hash_key -> list of positions (1-indexed) that had that hash.
  -- We only keep positions within the current window.
  local ht = {} -- ht[h] = array of positions

  local out = { header }
  local pos = 1   -- current position in input (1-indexed)

  while pos <= input_len do
    -- Can we attempt a match? Need at least min_match bytes remaining.
    local remaining = input_len - pos + 1

    if remaining >= min_match then
      local h = hash3(input, pos, window_size)
      local chain = ht[h]

      -- Search the chain for the best match
      local best_len  = 0
      local best_dist = 0

      if chain then
        local checked = 0
        for i = #chain, 1, -1 do   -- newest first
          local cand = chain[i]
          local dist = pos - cand
          if dist > window_size then break end  -- outside window; chain is sorted ascending so older ones are even further
          if dist > 0 then
            -- Measure match length
            local max_len = math.min(max_match, remaining)
            local mlen = 0
            while mlen < max_len and byte(input, pos + mlen) == byte(input, cand + mlen) do
              mlen = mlen + 1
            end
            if mlen > best_len then
              best_len  = mlen
              best_dist = dist
            end
            if best_len == max_match then break end -- can't do better
          end
          checked = checked + 1
          if checked >= MAX_CHAIN then break end
        end
      end

      -- Add current position to hash chain
      if not chain then
        ht[h] = { pos }
      else
        chain[#chain + 1] = pos
      end

      if best_len >= min_match then
        -- Emit match token
        out[#out + 1] = char(TOK_MATCH) .. le16(best_dist) .. le16(best_len)
        -- Add hash entries for skipped positions
        for skip = 1, best_len - 1 do
          local sp = pos + skip
          if sp + 2 <= input_len then
            local sh = hash3(input, sp, window_size)
            local sc = ht[sh]
            if not sc then
              ht[sh] = { sp }
            else
              sc[#sc + 1] = sp
            end
          end
        end
        pos = pos + best_len
      else
        -- Emit literal token
        out[#out + 1] = char(TOK_LITERAL, byte(input, pos))
        pos = pos + 1
      end
    else
      -- Not enough bytes for a match; emit literal(s)
      -- Also add to hash if possible
      if remaining >= min_match then
        local h = hash3(input, pos, window_size)
        local chain = ht[h]
        if not chain then ht[h] = { pos } else chain[#chain + 1] = pos end
      end
      out[#out + 1] = char(TOK_LITERAL, byte(input, pos))
      pos = pos + 1
    end
  end

  -- End of stream
  out[#out + 1] = char(TOK_END)

  return concat(out), nil
end

-- ── Decompression ────────────────────────────────────────────────────────────

--: (string) -> ((string | nil), (string | nil))
local function decompress(compressed)
  if type(compressed) ~= "string" then
    return nil, "input must be a string"
  end
  local clen = #compressed

  -- Check minimum size: 4 (magic) + 1 (window_bits) + 4 (orig_len) + 1 (TOK_END)
  if clen < 10 then
    return nil, "input too short"
  end

  -- Verify magic
  if sub(compressed, 1, 4) ~= MAGIC then
    return nil, "invalid magic bytes"
  end

  local window_bits = byte(compressed, 5)
  if window_bits < 1 or window_bits > 15 then
    return nil, "invalid window_bits in header"
  end

  local orig_len = read_le32(compressed, 6)
  local pos = 10  -- first token byte (1-indexed)

  -- Output buffer as table of chars; we'll join at the end.
  -- We also need random access into the output for back-references.
  -- Use a flat array of byte values for efficiency.
  local out_bytes = {}  -- out_bytes[i] = byte value at output position i (1-indexed)
  local out_pos = 0     -- number of bytes written so far

  while pos <= clen do
    local tok = byte(compressed, pos)
    pos = pos + 1

    if tok == TOK_END then
      break
    elseif tok == TOK_LITERAL then
      if pos > clen then
        return nil, "truncated: missing literal byte"
      end
      local b = byte(compressed, pos)
      pos = pos + 1
      out_pos = out_pos + 1
      out_bytes[out_pos] = b
    elseif tok == TOK_MATCH then
      -- Need 4 more bytes: 2 for distance, 2 for length
      if pos + 3 > clen then
        return nil, "truncated: incomplete match token"
      end
      local dist = read_le16(compressed, pos)
      local mlen = read_le16(compressed, pos + 2)
      pos = pos + 4

      if dist == 0 then
        return nil, "invalid match: distance is zero"
      end
      local start = out_pos - dist + 1
      if start < 1 then
        return nil, "invalid match: distance exceeds output"
      end
      -- Copy byte-by-byte to handle overlapping matches correctly
      for i = 0, mlen - 1 do
        out_pos = out_pos + 1
        out_bytes[out_pos] = out_bytes[start + i]
      end
    else
      return nil, "unknown token type: " .. tostring(tok)
    end
  end

  if out_pos ~= orig_len then
    return nil, "decompressed length mismatch: expected " .. orig_len .. ", got " .. out_pos
  end

  -- Build output string
  local chars = {}
  for i = 1, out_pos do
    chars[i] = char(out_bytes[i])
  end
  return concat(chars), nil
end

-- ── Streaming compressor ──────────────────────────────────────────────────────

--: (({ window_bits: (number | nil), min_match: (number | nil), max_match: (number | nil) } | nil)) -> { write: (string) -> nil, finish: () -> (string | nil) }
local function compressor(opts)
  local buf = {}
  return {
    write = function(self, chunk)
      buf[#buf + 1] = chunk
    end,
    finish = function(self)
      local input = concat(buf)
      local result, err = compress(input, opts)
      return result, err
    end,
  }
end

-- ── Streaming decompressor ────────────────────────────────────────────────────

--: () -> { write: (string) -> nil, finish: () -> (string | nil) }
local function decompressor()
  local buf = {}
  return {
    write = function(self, chunk)
      buf[#buf + 1] = chunk
    end,
    finish = function(self)
      local input = concat(buf)
      local result, err = decompress(input)
      return result, err
    end,
  }
end

-- ── Module exports ────────────────────────────────────────────────────────────

M.compress     = compress
M.decompress   = decompress
M.compressor   = compressor
M.decompressor = decompressor
-- Codec aliases
M.encode = compress
M.decode = decompress

return M
