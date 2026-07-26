-- lib/pdf/filter.lua
-- PDF stream filter decoding (ISO 32000-1 §7.4).
--
-- Shared by lib/pdf/xref.lua (cross-reference streams are PDF streams like
-- any other) and lib/pdf's top-level document resolver (any stream object —
-- content streams, image data, embedded files, ...). Given a stream's
-- dictionary and raw (still-encoded) bytes, applies /Filter and any
-- /DecodeParms /Predictor to recover the underlying data.
--
-- Implemented filters: FlateDecode, ASCII85Decode, ASCIIHexDecode,
-- RunLengthDecode, LZWDecode. /Filter may be a single name or an array
-- (a filter chain, ISO 32000-1 §7.4 Table 6 — applied in array order, each
-- with its own /DecodeParms array element); both forms are supported.
-- Unsupported filters (image-specific: DCTDecode, CCITTFaxDecode,
-- JBIG2Decode, JPXDecode; and Crypt) return a clear error rather than
-- silently passing through undecoded bytes. Only the PNG predictor family
-- (/Predictor 10-15) is implemented; the TIFF predictor (/Predictor 2,
-- rare in practice) returns a clear "not yet implemented" error — a
-- documented gap, not silent mishandling — see TODO.md. /Predictor is only
-- meaningful for FlateDecode/LZWDecode (ISO 32000-1 §7.4.4.4) so it's
-- applied only immediately after those two filters in a chain, never after
-- ASCII85/ASCIIHex/RunLength.
--
-- Errors: `(nil, errmsg)`, per docs/conventions.md.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ok_compress, compress_mod = pcall(require, "lib.compress")

local M = {}
M._tier = "pure"

local floor = math.floor
local char, sub, concat, rep = string.char, string.sub, table.concat, string.rep

-- TYPECHECKER WORKAROUND: calling string.byte's overloaded (intersection)
-- signature directly and using the result in a comparison inside a loop with
-- `break` spuriously narrows the result to `never` instead of `integer | nil`
-- — see TODO.md ("found while implementing lib/pdf/xref.lua"). Wrapping it in
-- a local single-signature function avoids the overload resolver entirely.
--: (string, integer) -> integer | nil
local function byte(s, pos)
	return string.byte(s, pos)
end

-- ── Narrowing helpers over `unknown` PDF values ──────────────────────────────
-- Mirrors the pattern lib/pdf/object_test.lua and lib/pdf/xref.lua use.

--: (unknown) -> { [string]: unknown, [integer]: unknown } | nil
local function as_table(v)
	if type(v) == "table" then return v end
	return nil
end

--: (unknown) -> string | nil
local function as_name(v)
	local t = as_table(v)
	if t == nil then return nil end
	if t.kind ~= "name" then return nil end
	local val = t.value
	if type(val) == "string" then return val end
	return nil
end

--: (unknown) -> number | nil
local function as_number(v)
	if type(v) == "number" then return v end
	return nil
end

--: (unknown) -> integer | nil
local function as_integer(v)
	local n = as_number(v)
	if n == nil then return nil end
	return floor(n)
end

--: (unknown) -> { [integer]: unknown } | nil
local function as_array(v)
	-- Arrays and dictionaries are both plain, untagged tables in
	-- lib/pdf/object.lua's representation; /Filter and /DecodeParms are
	-- spec-mandated to be arrays (when in array form), so there's no
	-- separate discriminator to check here.
	return as_table(v)
end

-- ── ASCII85Decode (ISO 32000-1 §7.4.3) ──────────────────────────────────────
-- Base-85: groups of 5 ASCII bytes (each in '!'(33)..'u'(117)) decode to 4
-- output bytes as a big-endian base-85 integer; the shorthand byte 'z' alone
-- represents an all-zero 4-byte group. Terminated by the "~>" EOD marker (if
-- present — a caller may already have stripped it via /Length); a partial
-- final group of n (2-5) input bytes, padded with 'u' to 5, yields n-1
-- output bytes. A lone trailing byte (group length 1) is invalid input.

local WS = { [0] = true, [9] = true, [10] = true, [12] = true, [13] = true, [32] = true }

--: (string) -> (string | nil, string | nil)
local function ascii85_decode(data)
	local s = data
	if sub(s, 1, 2) == "<~" then s = sub(s, 3) end
	local tilde = s:find("~>", 1, true)
	if tilde ~= nil then s = sub(s, 1, tilde - 1) end

	local out = {}
	local group = {} --[[: { [integer]: integer } ]]
	local n = #s
	local i = 1
	while i <= n do
		local b = byte(s, i)
		if b == nil then break end
		if WS[b] then
			i = i + 1
		elseif b == 122 and #group == 0 then -- 'z' shorthand for an all-zero group
			out[#out + 1] = "\0\0\0\0"
			i = i + 1
		else
			if b < 33 or b > 117 then
				return nil, "invalid ASCII85Decode byte " .. b .. " at offset " .. i
			end
			group[#group + 1] = b - 33
			i = i + 1
			if #group == 5 then
				local v = ((group[1] * 85 + group[2]) * 85 + group[3]) * 85 + group[4]
				v = v * 85 + group[5]
				out[#out + 1] = char(floor(v / 16777216) % 256, floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
				group = {}
			end
		end
	end

	if #group == 1 then
		return nil, "invalid ASCII85Decode data: trailing single-byte group"
	elseif #group > 0 then
		local count = #group
		for k = count + 1, 5 do group[k] = 84 end -- pad with 'u' - 33 = 84
		local v = ((group[1] * 85 + group[2]) * 85 + group[3]) * 85 + group[4]
		v = v * 85 + group[5]
		local four = char(floor(v / 16777216) % 256, floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
		out[#out + 1] = sub(four, 1, count - 1)
	end
	return concat(out), nil
end

-- ── ASCIIHexDecode (ISO 32000-1 §7.4.2) ─────────────────────────────────────
-- Pairs of hex digits (whitespace ignored), terminated by '>'; an odd
-- trailing digit is padded with an implicit 0 nibble (same rule as a PDF hex
-- string, ISO 32000-1 §7.3.4.3).

local HEX_VAL = {}
do
	for i = 0, 9 do HEX_VAL[48 + i] = i end       -- '0'-'9'
	for i = 0, 5 do HEX_VAL[65 + i] = 10 + i end  -- 'A'-'F'
	for i = 0, 5 do HEX_VAL[97 + i] = 10 + i end  -- 'a'-'f'
end

--: (string) -> (string | nil, string | nil)
local function asciihex_decode(data)
	local digits = {} --[[: { [integer]: integer } ]]
	local n = #data
	local i = 1
	while i <= n do
		local b = byte(data, i)
		if b == nil then break end
		if b == 62 then break end -- '>' EOD marker
		if not WS[b] then
			local v = HEX_VAL[b]
			if v == nil then return nil, "invalid hex digit in ASCIIHexDecode stream at offset " .. i end
			digits[#digits + 1] = v
		end
		i = i + 1
	end
	if #digits % 2 == 1 then digits[#digits + 1] = 0 end
	local out = {}
	for k = 1, #digits, 2 do
		out[#out + 1] = char(digits[k] * 16 + digits[k + 1])
	end
	return concat(out), nil
end

-- ── RunLengthDecode (ISO 32000-1 §7.4.5) ────────────────────────────────────
-- A length byte 0-127 means "copy the next (length+1) bytes literally";
-- 129-255 means "repeat the single following byte (257-length) times";
-- 128 is the EOD marker.

--: (string) -> (string | nil, string | nil)
local function runlength_decode(data)
	local out = {}
	local n = #data
	local i = 1
	while i <= n do
		local len = byte(data, i)
		if len == nil then break end
		i = i + 1
		if len == 128 then
			break
		elseif len < 128 then
			local count = len + 1
			if i + count - 1 > n then return nil, "truncated RunLengthDecode literal run" end
			out[#out + 1] = sub(data, i, i + count - 1)
			i = i + count
		else
			local count = 257 - len
			local b = byte(data, i)
			if b == nil then return nil, "truncated RunLengthDecode repeat run" end
			out[#out + 1] = rep(char(b), count)
			i = i + 1
		end
	end
	return concat(out), nil
end

-- ── LZWDecode (ISO 32000-1 §7.4.4) ──────────────────────────────────────────
-- Variable-width (9-12 bit) LZW over a 256-entry literal-byte table plus
-- codes 256 (Clear) and 257 (EOD). /DecodeParms /EarlyChange (default 1)
-- controls whether the code width increases one code early (Adobe's
-- historical convention, the PDF default) or exactly at the dictionary-full
-- boundary (TIFF-style, EarlyChange 0).

--: (integer, integer) -> integer
-- Code width needed to write the NEXT code, given the dictionary's next
-- free code number.
local function lzw_code_width(next_code, early_change)
	local n = next_code - 1
	if early_change == 1 then n = n + 1 end
	if n < 511 then return 9 end
	if n < 1023 then return 10 end
	if n < 2047 then return 11 end
	return 12
end

--: (string, integer | nil) -> (string | nil, string | nil)
local function lzw_decode(data, early_change)
	if early_change == nil then early_change = 1 end
	local CLEAR, EOD = 256, 257

	local dict = {} --[[: { [integer]: string } ]]
	local next_code = 258 --: integer
	local code_width = 9 --: integer
	--: () -> nil
	local function reset_dict()
		dict = {}
		for i = 0, 255 do dict[i] = char(i) end
		next_code = 258
		code_width = 9
	end
	reset_dict()

	local total_bits = #data * 8
	local bitpos = 0
	--: (integer) -> integer | nil
	local function read_code(width)
		if bitpos + width > total_bits then return nil end
		local code = 0
		for _ = 1, width do
			local byte_idx = floor(bitpos / 8) + 1
			local bit_idx = 7 - (bitpos % 8)
			local byte_val = byte(data, byte_idx) or 0
			local bit = floor(byte_val / (2 ^ bit_idx)) % 2
			code = code * 2 + bit
			bitpos = bitpos + 1
		end
		return code
	end

	local out = {}
	local prev = nil --: string | nil
	while true do
		local code = read_code(code_width)
		if code == nil or code == EOD then break end
		if code == CLEAR then
			reset_dict()
			prev = nil
		else
			local entry
			if dict[code] ~= nil then
				entry = dict[code]
			elseif code == next_code and prev ~= nil then
				entry = prev .. sub(prev, 1, 1)
			else
				return nil, "invalid LZWDecode code sequence (code " .. code .. ")"
			end
			out[#out + 1] = entry
			if prev ~= nil then
				dict[next_code] = prev .. sub(entry, 1, 1)
				next_code = next_code + 1
				code_width = lzw_code_width(next_code, early_change)
			end
			prev = entry
		end
	end
	return concat(out), nil
end

-- ── PNG predictor un-filtering (used by /DecodeParms /Predictor 10-15) ──────
-- Same algorithm PNG scanline filtering uses (lib/png does not implement
-- this — it passes IDAT through opaquely — so this is not a duplicate of
-- existing code). Needed because FlateDecode+Predictor is the overwhelmingly
-- common encoding real-world PDF producers use; without it, affected streams
-- would decode to structured garbage instead of correct data or a clear error.

--: (integer | nil) -> integer
local function or_zero(v)
	if v == nil then return 0 end
	return v
end

--: (integer, integer, integer) -> integer
local function paeth_predictor(a, b, c)
	local p = a + b - c
	local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
	if pa <= pb and pa <= pc then return a end
	if pb <= pc then return b end
	return c
end

--: (string, integer, integer) -> (string | nil, string | nil)
local function png_unfilter(data, row_bytes, bpp)
	local out = {}
	local prior = string.rep("\0", row_bytes)
	local stride = row_bytes + 1
	local n = #data
	local pos = 1
	while pos + stride - 1 <= n do
		local filter_type = byte(data, pos)
		local row = {} --[[: { [integer]: integer } ]]
		for x = 1, row_bytes do
			local raw = byte(data, pos + x)
			if raw == nil then return nil, "truncated PNG-filtered row" end

			local a = 0
			if x > bpp then a = or_zero(row[x - bpp]) end
			local b = or_zero(byte(prior, x))
			local c = 0
			if x > bpp then c = or_zero(byte(prior, x - bpp)) end

			local recon
			if filter_type == 0 then
				recon = raw
			elseif filter_type == 1 then
				recon = raw + a
			elseif filter_type == 2 then
				recon = raw + b
			elseif filter_type == 3 then
				recon = raw + floor((a + b) / 2)
			elseif filter_type == 4 then
				recon = raw + paeth_predictor(a, b, c)
			else
				return nil, "unsupported PNG filter type byte: " .. tostring(filter_type)
			end
			row[x] = recon % 256
		end
		local row_str = string.char(unpack(row, 1, row_bytes))
		out[#out + 1] = row_str
		prior = row_str
		pos = pos + stride
	end
	return table.concat(out), nil
end

-- ── Predictor dispatch ───────────────────────────────────────────────────────

--: (unknown) -> integer
-- Reads /Predictor from a /DecodeParms dictionary (default 1, meaning "no
-- predictor" per ISO 32000-1 Table 8).
local function read_predictor(decode_parms)
	local dp = as_table(decode_parms)
	if dp == nil then return 1 end
	local predictor = as_integer(dp.Predictor)
	if predictor == nil then return 1 end
	return predictor
end

--: (unknown, string, integer) -> (string | nil, string | nil)
-- `default_columns` is the un-predicted row width to fall back on when
-- /DecodeParms /Columns is absent (xref streams: their row width; other
-- streams should always specify /Columns, but this keeps the function total).
local function apply_predictor(decode_parms, data, default_columns)
	local predictor = read_predictor(decode_parms)
	if predictor == 1 then return data, nil end
	if predictor == 2 then
		return nil, "TIFF predictor (/Predictor 2) is not yet implemented"
	end
	if predictor < 10 or predictor > 15 then
		return nil, "unsupported /Predictor value: " .. tostring(predictor)
	end

	local dp = as_table(decode_parms)
	local columns = default_columns
	local colors = 1
	local bpc = 8
	if dp ~= nil then
		local cols = as_integer(dp.Columns)
		if cols ~= nil then columns = cols end
		local c = as_integer(dp.Colors)
		if c ~= nil then colors = c end
		local b = as_integer(dp.BitsPerComponent)
		if b ~= nil then bpc = b end
	end
	local bpp = math.max(1, math.ceil(colors * bpc / 8))
	return png_unfilter(data, columns, bpp)
end

-- ── Filter-name and DecodeParms list resolution ─────────────────────────────
-- /Filter is either a single name (one filter) or an array of names (a
-- chain, applied in array order — ISO 32000-1 §7.4 "if there are multiple
-- filters... they are applied in the order in which they appear"). Whichever
-- form /Filter takes, /DecodeParms (or its PDF-1.2-era alias /DP) follows
-- the same shape: a single dict (or null/absent) paired with a single
-- filter, or a parallel array (each element a dict, or null for "no parms
-- for this filter") paired with a filter-name array of the same length.

--: ({ [string]: unknown, [integer]: unknown }) -> ({ [integer]: string } | nil, string | nil)
local function resolve_filter_names(d)
	if d.Filter == nil then return {}, nil end
	local single = as_name(d.Filter)
	if single ~= nil then return { single }, nil end
	local arr = as_array(d.Filter)
	if arr == nil then
		return nil, "unsupported /Filter value (not a name, not an array — "
			.. "possibly an unresolved indirect reference)"
	end
	local names = {} --[[: { [integer]: string } ]]
	local i = 1
	while arr[i] ~= nil do
		local name = as_name(arr[i])
		if name == nil then return nil, "/Filter array element " .. i .. " is not a name" end
		names[i] = name
		i = i + 1
	end
	return names, nil
end

--: ({ [string]: unknown, [integer]: unknown }, integer) -> { [integer]: unknown }
-- Returns a 1-indexed list, length `count`, of each filter's DecodeParms
-- entry (`unknown` — narrowed to a dict per-element by the caller, since a
-- parallel-array slot may legitimately be `null`/absent for one filter).
local function resolve_parms_list(d, count)
	local decode_parms = d.DecodeParms
	if decode_parms == nil then decode_parms = d.DP end
	local list = {} --[[: { [integer]: unknown } ]]
	if count <= 1 then
		list[1] = decode_parms
		return list
	end
	local arr = as_array(decode_parms)
	for i = 1, count do
		if arr ~= nil then
			list[i] = arr[i]
		else
			list[i] = nil
		end
	end
	return list
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Decode a stream's raw bytes per its dictionary's /Filter and /DecodeParms,
-- applying a filter chain in order when /Filter is an array.
-- `default_columns` (optional) sets the predictor row width to use when
-- /DecodeParms /Columns is absent — callers that know the natural row width
-- of their data (e.g. lib/pdf/xref.lua, whose rows are /W-width fixed
-- records) should pass it; general callers can omit it (defaults to the
-- full data length, i.e. one row) since general streams should carry /Columns.
--: (unknown, string, integer | nil) -> (string | nil, string | nil)
function M.decode_stream(dict, raw_data, default_columns)
	local d = as_table(dict)
	if d == nil then return nil, "stream dictionary is not a dictionary" end

	local filter_names, nerr = resolve_filter_names(d)
	if filter_names == nil then return nil, nerr end
	local parms_list = resolve_parms_list(d, #filter_names)

	local data = raw_data

	if #filter_names == 0 then
		-- No /Filter at all: predictor-only data (e.g. an xref stream with no
		-- compression filter, just a /DecodeParms /Predictor). /Predictor is
		-- spec-tied to FlateDecode/LZWDecode, but callers exercising a bare
		-- /DecodeParms with no filter are relying on this pass-through — same
		-- behavior as before filter chains were supported.
		return apply_predictor(parms_list[1], data, default_columns or #data)
	end

	local i = 1
	while filter_names[i] ~= nil do
		local filter_name = filter_names[i]
		local parms = parms_list[i]

		if filter_name == "FlateDecode" then
			if not ok_compress then
				return nil, "stream uses FlateDecode but lib/compress is unavailable"
			end
			local inflated, ierr = compress_mod.inflate(data)
			if inflated == nil then return nil, "failed to inflate stream: " .. tostring(ierr) end
			data = inflated
			local predicted, perr = apply_predictor(parms, data, default_columns or #data)
			if predicted == nil then return nil, perr end
			data = predicted
		elseif filter_name == "LZWDecode" then
			local pd = as_table(parms)
			local early_change = 1
			if pd ~= nil then
				local ec = as_integer(pd.EarlyChange)
				if ec ~= nil then early_change = ec end
			end
			local decoded, lerr = lzw_decode(data, early_change)
			if decoded == nil then return nil, lerr end
			data = decoded
			local predicted, perr = apply_predictor(parms, data, default_columns or #data)
			if predicted == nil then return nil, perr end
			data = predicted
		elseif filter_name == "ASCII85Decode" then
			local decoded, aerr = ascii85_decode(data)
			if decoded == nil then return nil, aerr end
			data = decoded
		elseif filter_name == "ASCIIHexDecode" then
			local decoded, aerr = asciihex_decode(data)
			if decoded == nil then return nil, aerr end
			data = decoded
		elseif filter_name == "RunLengthDecode" then
			local decoded, rerr = runlength_decode(data)
			if decoded == nil then return nil, rerr end
			data = decoded
		else
			return nil, "unsupported stream filter: " .. filter_name
		end

		i = i + 1
	end

	return data, nil
end

return M
