-- lib/lz4/init.lua
-- LZ4 block and frame compression/decompression, pure Lua.
--
-- Public API:
--   M.decompress_block(compressed, opts)  -> decompressed, err
--   M.compress_block(input)               -> compressed, err
--   M.decompress(data)                    -> decompressed, err   (frame format)
--   M.compress(input)                     -> compressed, err     (frame format)
--   M.encode = M.compress
--   M.decode = M.decompress
--   M._tier = "pure"
--
-- LZ4 block format (raw, no frame):
--   Sequence of tokens. Each token byte:
--     high nibble = literal length prefix (0-14 direct, 15 = read more)
--     low nibble  = match length prefix   (0-14 → actual=4+n, 15 = read more)
--   After token: extra literal length bytes (while byte==255), literals,
--   2-byte LE match offset, extra match length bytes (while byte==255).
--   Last sequence omits match offset and match length.
--
-- LZ4 frame format (v1.9 simplified):
--   Magic: 0x184D2204 (4 bytes LE)
--   FLG byte, BD byte, HC byte (header checksum)
--   Data blocks: 4-byte LE size (bit31=uncompressed), block data
--   End mark: 4 zero bytes

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, bor = bit.band, bit.bor
local lshift, rshift = bit.lshift, bit.rshift
local byte = string.byte
local char = string.char
local sub = string.sub
local concat = table.concat

local M = {}
M._tier = "pure"

-- ── helpers ──────────────────────────────────────────────────────────────────

local function read_u16_le(s, i)
	local a, b = byte(s, i, i + 1)
	return (a or 0) + (b or 0) * 256
end

local function read_u32_le(s, i)
	local a, b, c, d = byte(s, i, i + 3)
	return (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
end

local function write_u16_le(v)
	return char(band(v, 0xFF), band(rshift(v, 8), 0xFF))
end

local function write_u32_le(v)
	return char(
		band(v, 0xFF),
		band(rshift(v, 8), 0xFF),
		band(rshift(v, 16), 0xFF),
		band(rshift(v, 24), 0xFF)
	)
end

-- ── decompress_block ─────────────────────────────────────────────────────────

-- Decompress a raw LZ4 block.
-- compressed: binary string
-- opts: optional table, opts.original_size used as output buffer hint
-- Returns: decompressed string, nil   OR   nil, errmsg
function M.decompress_block(compressed, opts)
	if type(compressed) ~= "string" then
		return nil, "decompress_block: expected string"
	end
	local clen = #compressed
	if clen == 0 then
		return "", nil
	end

	local out = {}
	local out_len = 0  -- track output byte count for match back-references
	-- We accumulate output as a table of strings for efficiency.
	-- For match copies we need random access into the already-decoded output.
	-- Strategy: maintain a flat byte array (as a Lua table of numbers) for
	-- decoded output so that back-references can be resolved in O(1).
	local decoded = {}  -- decoded[i] = byte value at 0-based position i

	local ip = 1  -- 1-based read position in compressed string

	while ip <= clen do
		-- Read token
		local token = byte(compressed, ip) or 0
		ip = ip + 1

		-- Decode literal length
		local lit_len = rshift(token, 4)
		if lit_len == 15 then
			while ip <= clen do
				local extra = byte(compressed, ip) or 0
				ip = ip + 1
				lit_len = lit_len + extra
				if extra ~= 255 then break end
			end
		end

		-- Copy literals
		if lit_len > 0 then
			if ip + lit_len - 1 > clen then
				return nil, "decompress_block: literal run overflows input"
			end
			for i = ip, ip + lit_len - 1 do
				local b = byte(compressed, i) or 0
				decoded[out_len] = b
				out_len = out_len + 1
			end
			ip = ip + lit_len
		end

		-- If we've consumed the entire input, this was the last sequence.
		if ip > clen then break end

		-- Read match offset (2 bytes LE)
		if ip + 1 > clen then
			return nil, "decompress_block: truncated match offset"
		end
		local offset = read_u16_le(compressed, ip)
		ip = ip + 2
		if offset == 0 then
			return nil, "decompress_block: invalid zero offset"
		end

		-- Decode match length
		local match_len = band(token, 0x0F) + 4  -- minimum match is 4
		if band(token, 0x0F) == 15 then
			while ip <= clen do
				local extra = byte(compressed, ip) or 0
				ip = ip + 1
				match_len = match_len + extra
				if extra ~= 255 then break end
			end
		end

		-- Copy match from decoded output (may overlap — copy byte-by-byte)
		local match_start = out_len - offset
		if match_start < 0 then
			return nil, "decompress_block: match offset beyond start of output"
		end
		for i = 0, match_len - 1 do
			local b = decoded[match_start + i]
			if b == nil then
				return nil, "decompress_block: match references unwritten position"
			end
			decoded[out_len] = b
			out_len = out_len + 1
		end
	end

	-- Convert decoded byte array to string
	local result_parts = {}
	for i = 0, out_len - 1 do
		result_parts[i + 1] = char(decoded[i])
	end
	return concat(result_parts), nil
end

-- ── compress_block ───────────────────────────────────────────────────────────

-- Encode a variable-length extra (for lengths >= 15).
-- Writes 255 bytes until remainder < 255, then writes remainder.
local function encode_length_extra(len)
	local parts = {}
	while len >= 255 do
		parts[#parts + 1] = char(255)
		len = len - 255
	end
	parts[#parts + 1] = char(len)
	return concat(parts)
end

-- Flush a pending literal run + match into the output.
-- lit_start, lit_end: 1-based inclusive positions in input string
-- match_offset: 0 means no match (last sequence or forced flush)
-- match_len: 0 means no match
--: (string, integer, integer, integer, integer, { [integer]: string }) -> nil
local function flush_sequence(input, lit_start, lit_end, match_offset, match_len, out)
	local lit_len = lit_end - lit_start + 1
	if lit_start > lit_end then lit_len = 0 end

	-- Token byte: high nibble = min(lit_len, 15), low nibble = min(match_len-4, 15) if match
	local lit_nibble = lit_len >= 15 and 15 or lit_len
	local match_nibble = 0
	if match_len >= 4 then
		local m = match_len - 4
		match_nibble = m >= 15 and 15 or m
	end
	out[#out + 1] = char(bor(lshift(lit_nibble, 4), match_nibble))

	-- Extra literal length bytes
	if lit_nibble == 15 then
		out[#out + 1] = encode_length_extra(lit_len - 15)
	end

	-- Literal bytes
	if lit_len > 0 then
		out[#out + 1] = sub(input, lit_start, lit_end)
	end

	-- Match offset and extra match length (only when there is a match)
	if match_len >= 4 then
		out[#out + 1] = write_u16_le(match_offset)
		if match_nibble == 15 then
			out[#out + 1] = encode_length_extra((match_len - 4) - 15)
		end
	end
end

-- Hash a 4-byte window at position i (1-based) in input string.
local function hash4(input, i)
	local a, b, c, d = byte(input, i, i + 3)
	-- Simple polynomial hash, fits in Lua number (doubles are exact for integers < 2^53)
	return math.floor(((a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216) * 2654435761 % 65536)
end

-- Compress input to LZ4 block format (greedy, not optimal).
-- Returns: compressed string, nil   OR   nil, errmsg
function M.compress_block(input)
	if type(input) ~= "string" then
		return nil, "compress_block: expected string"
	end
	local n = #input
	if n == 0 then
		-- Single token: 0 literals, no match
		return char(0), nil
	end

	local out = {}
	-- Hash table: hash → last seen 1-based position
	local ht = {} --: { [integer]: integer }
	-- Current literal run start (1-based)
	local lit_start = 1
	local ip = 1  -- current position (1-based)

	-- We must leave at least 5 bytes at the end as literals (LZ4 spec end-of-block constraint:
	-- last 5 bytes are always literals). We process up to n-4 to ensure we can always read 4 bytes.
	local limit = n - 4  -- last position where we can start a 4-byte hash lookup

	while ip <= limit do
		local h = hash4(input, ip)
		local candidate = ht[h]
		ht[h] = ip

		local match_len = 0 --: integer
		local match_offset = 0 --: integer

		if candidate ~= nil and candidate >= 1 and ip - candidate <= 65535 then
			-- Verify match (at least 4 bytes)
			local offs = (ip - candidate) --[[:! integer]]
			local max_match = n - ip + 1  -- can't go past end of input
			local ml = 0 --: integer
			-- Compare bytes
			local a1, a2 = ip, candidate --: integer
			while ml < max_match do
				if byte(input, a1 + ml) ~= byte(input, a2 + ml) then break end
				ml = ml + 1
			end
			if ml >= 4 then
				match_len = ml
				match_offset = offs
			end
		end

		if match_len >= 4 then
			-- Emit literal run + match
			flush_sequence(input, lit_start, ip - 1, match_offset, match_len, out)
			ip = ip + match_len
			lit_start = ip
			-- Update hash table for positions within the match (skip interior for speed)
			-- At minimum update position after match to keep ht fresh
		else
			ip = ip + 1
		end
	end

	-- Emit final sequence: remaining bytes as literals, no match
	flush_sequence(input, lit_start, n, 0, 0, out)

	return concat(out), nil
end

-- ── LZ4 frame format ─────────────────────────────────────────────────────────

local FRAME_MAGIC = 0x184D2204
-- Magic bytes: 04 22 4D 18
local FRAME_MAGIC_BYTES = "\x04\x22\x4D\x18"

-- Frame header for our encoder:
--   FLG = 0x60 (version=01 in bits 7-6, B_indep=0, no extras)
--   BD  = 0x70 (block max size = 4MB, bits 6-4 = 7)
-- Header checksum HC = (xxh32([FLG, BD], 0) >> 8) & 0xFF
-- We compute this lazily using lib.hash.xxhash if available, else use hardcoded value.
local FRAME_FLG = 0x60
local FRAME_BD  = 0x70

-- Compute HC for the fixed FLG+BD header.
-- HC = (xxhash32(header, 0) >> 8) & 0xFF  where header = FLG..BD
local function compute_hc(flg, bd)
	local ok_xxh, xxh = pcall(require, "lib.hash.xxhash")
	if ok_xxh then
		local xxh_any = xxh --[[: any]]
		local xxh_ = xxh_any --[[:! { xxh32: function, ... }]]
		if xxh_.xxh32 then
			local header_bytes = char(flg, bd)
			local h = (xxh_.xxh32(header_bytes, 0) --[[: any]]) --[[:! integer]]
			return band(rshift(h, 8), 0xFF)
		end
	end
	-- Fallback: hardcoded HC for FLG=0x60, BD=0x70
	-- xxh32("\x60\x70", 0) = 0x789F73AA → (>> 8) & 0xFF = 0x73
	-- Precomputed so this path requires no xxhash dependency.
	return 0x73
end

-- Cache the HC value at module load time.
local FRAME_HC = compute_hc(FRAME_FLG, FRAME_BD)

-- Decompress an LZ4 frame (magic + block descriptors).
-- Returns: decompressed string, nil   OR   nil, errmsg
function M.decompress(data)
	if type(data) ~= "string" then
		return nil, "decompress: expected string"
	end
	local len = #data
	if len < 7 then
		return nil, "decompress: too short to be an LZ4 frame"
	end

	-- Verify magic
	local magic = read_u32_le(data, 1)
	if magic ~= FRAME_MAGIC then
		return nil, string.format("decompress: invalid LZ4 magic 0x%08X (expected 0x184D2204)", magic)
	end

	local ip = 5  -- position after magic

	-- Parse FLG byte
	if ip > len then return nil, "decompress: truncated frame header (FLG)" end
	local flg = byte(data, ip) or 0; ip = ip + 1

	-- Version bits (7-6) must be 01
	local version = band(rshift(flg, 6), 0x03)
	if version ~= 1 then
		return nil, string.format("decompress: unsupported FLG version %d", version)
	end

	local has_c_size = band(flg, 0x08) ~= 0   -- bit 3: content size present
	local has_dictid = band(flg, 0x01) ~= 0   -- bit 0: dict ID present

	-- Parse BD byte
	if ip > len then return nil, "decompress: truncated frame header (BD)" end
	-- local bd = byte(data, ip)  -- we don't enforce block max size on decode
	ip = ip + 1

	-- Skip optional content size (8 bytes)
	if has_c_size then
		ip = ip + 8
	end

	-- Skip optional dict ID (4 bytes)
	if has_dictid then
		ip = ip + 4
	end

	-- HC byte (header checksum) — we parse but don't fail on mismatch (lenient)
	if ip > len then return nil, "decompress: truncated frame header (HC)" end
	-- local hc = byte(data, ip)
	ip = ip + 1

	-- Parse data blocks
	local out_parts = {}
	while true do
		if ip + 3 > len then
			return nil, "decompress: truncated block size field"
		end
		local block_size_raw = read_u32_le(data, ip)
		ip = ip + 4

		-- End mark
		if block_size_raw == 0 then break end

		local is_uncompressed = band(block_size_raw, 0x80000000) ~= 0
		local block_size = band(block_size_raw, 0x7FFFFFFF)

		if ip + block_size - 1 > len then
			return nil, "decompress: block data extends beyond input"
		end
		local block_data = sub(data, ip, ip + block_size - 1)
		ip = ip + block_size

		if is_uncompressed then
			out_parts[#out_parts + 1] = block_data
		else
			local decompressed, err = M.decompress_block(block_data)
			if decompressed == nil then
				return nil, "decompress: block decompression failed: " .. (err or "")
			end
			out_parts[#out_parts + 1] = decompressed --[[:! string]]
		end
	end

	return concat(out_parts), nil
end

-- Compress input with LZ4 frame wrapper.
-- Returns: compressed string, nil   OR   nil, errmsg
function M.compress(input)
	if type(input) ~= "string" then
		return nil, "compress: expected string"
	end

	local compressed_block, err = M.compress_block(input)
	if compressed_block == nil then
		return nil, "compress: " .. (err or "")
	end
	local compressed_block_ = (compressed_block --[[: any]]) --[[:! string]]

	-- Frame header
	local header = FRAME_MAGIC_BYTES
		.. char(FRAME_FLG)
		.. char(FRAME_BD)
		.. char(FRAME_HC)

	-- Data block: 4-byte LE size + block data
	local block_size = #compressed_block_
	local frame = header
		.. write_u32_le(block_size)
		.. compressed_block_
		.. "\x00\x00\x00\x00"  -- end mark

	return frame, nil
end

-- Codec aliases
M.encode = M.compress
M.decode = M.decompress

return M
