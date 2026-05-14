-- lib/png/init.lua
-- PNG chunk-level reader/writer.
-- Reads PNG bytes into a list of {type, data} chunks; writes them back.
-- IDAT (image data) is passed through as opaque bytes — never decoded.
-- tEXt/zTXt/iTXt helpers for metadata read/write on top of chunk access.
--
-- API:
--   png.read(bytes)                    -> chunks, err
--   png.write(chunks)                  -> bytes
--   png.get_text(chunks, keyword)      -> string | nil
--   png.set_text(chunks, keyword, val) -> new_chunks
--   png.remove_text(chunks, keyword)   -> new_chunks
--   png.parse_text(data)               -> {keyword, text} | nil, err
--   png.build_text(keyword, text)      -> data
--   png.get_itxt(chunks, keyword)      -> string | nil
--   png.set_itxt(chunks, keyword, val, opts) -> new_chunks
--   png.remove_itxt(chunks, keyword)   -> new_chunks
--   png.parse_itxt(data)               -> {keyword, text, language_tag, translated_keyword, compressed} | nil, err
--   png.build_itxt(keyword, text, opts) -> data

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")

local M = {}

local PNG_SIG = "\137PNG\r\n\26\n"

-- ── CRC-32 ────────────────────────────────────────────────────────────────────

local crc_table = {}
do
	for i = 0, 255 do
		local c = i
		for _ = 1, 8 do
			if bit.band(c, 1) ~= 0 then
				c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
			else
				c = bit.rshift(c, 1)
			end
		end
		crc_table[i] = c
	end
end

local function crc32(s)
	local crc = bit.bnot(0)  -- 0xFFFFFFFF
	for i = 1, #s do
		local b = string.byte(s, i)
		crc = bit.bxor(
			bit.rshift(crc, 8),
			crc_table[bit.band(bit.bxor(crc, b), 0xFF)]
		)
	end
	return bit.bnot(crc)
end

-- ── Byte I/O ──────────────────────────────────────────────────────────────────

--: (s: string, i: integer) -> integer
local function read_u32(s, i)
	local a = string.byte(s, i) --[[:! integer]]
	local b = string.byte(s, i + 1) --[[:! integer]]
	local c = string.byte(s, i + 2) --[[:! integer]]
	local d = string.byte(s, i + 3) --[[:! integer]]
	return (a * 0x1000000 + b * 0x10000 + c * 0x100 + d) --[[:! integer]]
end

local function write_u32(n)
	if n < 0 then n = n + 0x100000000 end  -- signed→unsigned for CRC values
	local d = n % 256; n = math.floor(n / 256)
	local c = n % 256; n = math.floor(n / 256)
	local b = n % 256; n = math.floor(n / 256)
	local a = n % 256
	return string.char(a, b, c, d)
end

-- ── Chunk I/O ─────────────────────────────────────────────────────────────────

-- read(bytes) -> chunks | nil, err
-- Returns an array of {type=string, data=string} in file order.
-- Stops at IEND (inclusive). IDAT bytes are passed through untouched.
--: (bytes: string) -> ({ [integer]: { type: string, data: string } } | nil, string | nil)
function M.read(bytes)
	if bytes:sub(1, 8) ~= PNG_SIG then
		return nil, "not a PNG file"
	end

	local chunks = {}
	local pos = 9  -- first byte after the 8-byte signature

	while pos <= #bytes do
		if pos + 11 > #bytes then
			return nil, "truncated chunk at offset " .. pos
		end

		local length = read_u32(bytes, pos)
		local chunk_type = bytes:sub(pos + 4, pos + 7)
		local data = length > 0 and bytes:sub(pos + 8, pos + 7 + length) or ""

		chunks[#chunks + 1] = { type = chunk_type, data = data }

		pos = pos + 12 + length

		if chunk_type == "IEND" then break end
	end

	return chunks
end

-- write(chunks) -> bytes
-- Serialises chunks to a valid PNG byte string with correct CRCs.
function M.write(chunks)
	local parts = { PNG_SIG }
	for _, chunk in ipairs(chunks) do
		local data = chunk.data or ""
		parts[#parts + 1] = write_u32(#data)
		parts[#parts + 1] = chunk.type
		parts[#parts + 1] = data
		parts[#parts + 1] = write_u32(crc32(chunk.type .. data))
	end
	return table.concat(parts)
end

-- ── tEXt helpers ──────────────────────────────────────────────────────────────
-- tEXt data layout: <keyword> NUL <text>
-- keyword: 1–79 bytes, latin-1, no NUL.
-- text:    latin-1, no NUL, any length.

-- parse_text(data) -> {keyword, text} | nil, err
--: (data: string) -> ({ keyword: string, text: string } | nil, string | nil)
function M.parse_text(data)
	local sep = data:find("\0", 1, true)
	if not sep then
		return nil, "malformed tEXt: missing NUL separator"
	end
	return { keyword = data:sub(1, sep - 1), text = data:sub(sep + 1) }
end

-- build_text(keyword, text) -> data string
function M.build_text(keyword, text)
	return keyword .. "\0" .. text
end

-- get_text(chunks, keyword) -> string | nil
-- Returns the text value for the first tEXt chunk with the given keyword.
function M.get_text(chunks, keyword)
	for _, chunk in ipairs(chunks) do
		if chunk.type == "tEXt" then
			local entry = M.parse_text(chunk.data)
			if entry and entry.keyword == keyword then
				return entry.text
			end
		end
	end
	return nil
end

-- set_text(chunks, keyword, value) -> new_chunks
-- Replaces the first tEXt chunk with this keyword, or inserts one before IEND.
-- Returns a new chunk list; original is not modified.
function M.set_text(chunks, keyword, value)
	local new_chunk = { type = "tEXt", data = M.build_text(keyword, value) }
	local result = {}
	local done = false

	for _, chunk in ipairs(chunks) do
		if chunk.type == "tEXt" then
			local entry = M.parse_text(chunk.data)
			if entry and entry.keyword == keyword and not done then
				result[#result + 1] = new_chunk  -- replace
				done = true
			else
				result[#result + 1] = chunk
			end
		elseif chunk.type == "IEND" and not done then
			result[#result + 1] = new_chunk  -- insert before IEND
			result[#result + 1] = chunk
			done = true
		else
			result[#result + 1] = chunk
		end
	end

	if not done then
		result[#result + 1] = new_chunk
	end

	return result
end

-- remove_text(chunks, keyword) -> new_chunks
-- Returns a new chunk list with all tEXt chunks for keyword removed.
function M.remove_text(chunks, keyword)
	local result = {}
	for _, chunk in ipairs(chunks) do
		if chunk.type == "tEXt" then
			local entry = M.parse_text(chunk.data)
			if not (entry and entry.keyword == keyword) then
				result[#result + 1] = chunk
			end
		else
			result[#result + 1] = chunk
		end
	end
	return result
end

-- ── iTXt helpers ──────────────────────────────────────────────────────────────
-- iTXt data layout: <keyword> NUL compression_flag(1) compression_method(1)
--                   <language_tag> NUL <translated_keyword> NUL <text>
-- Only uncompressed (flag=0, method=0) is supported for build.

-- parse_itxt(data) -> {keyword, text, language_tag, translated_keyword, compressed} | nil, err
--: (data: string) -> (unknown | nil, string | nil)
function M.parse_itxt(data)
	local sep = data:find("\0", 1, true)
	if not sep then
		return nil, "malformed iTXt: missing keyword NUL separator"
	end
	if sep + 2 > #data then
		return nil, "malformed iTXt: truncated after keyword"
	end
	local sep = sep --[[:! integer]]
	local keyword = data:sub(1, sep - 1)
	local compression_flag = data:byte((sep + 1) --[[:! integer]])
	-- sep+2 is compression_method, sep+3 is start of language_tag
	local lang_start = sep + 3
	local lang_end = data:find("\0", lang_start, true)
	if not lang_end then
		return nil, "malformed iTXt: missing language_tag NUL"
	end
	local tkey_end = data:find("\0", lang_end + 1, true)
	if not tkey_end then
		return nil, "malformed iTXt: missing translated_keyword NUL"
	end
	return {
		keyword = keyword,
		text = data:sub(tkey_end + 1),
		language_tag = data:sub(lang_start, lang_end - 1),
		translated_keyword = data:sub(lang_end + 1, tkey_end - 1),
		compressed = compression_flag ~= 0,
	}
end

-- build_itxt(keyword, text, opts) -> data string
-- opts.language_tag and opts.translated_keyword default to "".
-- Always builds uncompressed (flag=0, method=0).
function M.build_itxt(keyword, text, opts)
	local lang = (opts and opts.language_tag) or ""
	local tkey = (opts and opts.translated_keyword) or ""
	return keyword .. "\0\0\0" .. lang .. "\0" .. tkey .. "\0" .. text
end

-- get_itxt(chunks, keyword) -> string | nil
-- Returns the text value of the first uncompressed iTXt chunk with the given keyword.
--: (chunks: { [integer]: { type: string, data: string, ... } }, keyword: string) -> string | nil
function M.get_itxt(chunks, keyword)
	for _, chunk in ipairs(chunks) do
		if chunk.type == "iTXt" then
			local entry_raw = M.parse_itxt(chunk.data)
			local entry = entry_raw --[[:! { keyword: string, text: string, compressed: boolean } | nil]]
			if entry and entry.keyword == keyword and not entry.compressed then
				return entry.text
			end
		end
	end
	return nil
end

-- set_itxt(chunks, keyword, value, opts) -> new_chunks
-- Replaces the first iTXt chunk with this keyword, or inserts one before IEND.
-- Returns a new chunk list; original is not modified.
function M.set_itxt(chunks, keyword, value, opts)
	local new_chunk = { type = "iTXt", data = M.build_itxt(keyword, value, opts) }
	local result = {}
	local done = false

	for _, chunk in ipairs(chunks) do
		if chunk.type == "iTXt" then
			local entry_raw = M.parse_itxt(chunk.data)
			local entry = entry_raw --[[:! { keyword: string } | nil]]
			if entry and entry.keyword == keyword and not done then
				result[#result + 1] = new_chunk  -- replace
				done = true
			else
				result[#result + 1] = chunk
			end
		elseif chunk.type == "IEND" and not done then
			result[#result + 1] = new_chunk  -- insert before IEND
			result[#result + 1] = chunk
			done = true
		else
			result[#result + 1] = chunk
		end
	end

	if not done then
		result[#result + 1] = new_chunk
	end

	return result
end

-- remove_itxt(chunks, keyword) -> new_chunks
-- Returns a new chunk list with all iTXt chunks for keyword removed.
function M.remove_itxt(chunks, keyword)
	local result = {}
	for _, chunk in ipairs(chunks) do
		if chunk.type == "iTXt" then
			local entry_raw = M.parse_itxt(chunk.data)
			local entry = entry_raw --[[:! { keyword: string } | nil]]
			if not (entry and entry.keyword == keyword) then
				result[#result + 1] = chunk
			end
		else
			result[#result + 1] = chunk
		end
	end
	return result
end

return M
