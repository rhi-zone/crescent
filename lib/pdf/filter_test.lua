-- lib/pdf/filter_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local filter = require("lib.pdf.filter")
local compress = require("lib.compress")

-- Same string.byte-overload-in-loop gap recorded in TODO.md: wrap it in a
-- local single-signature function.
--: (string, integer) -> integer | nil
local function byte_at(s, pos)
	return string.byte(s, pos)
end

--: ({ [integer]: integer }, integer) -> string
local function bytes_to_string(t, n)
	local chars = {}
	for i = 1, n do chars[i] = string.char(t[i]) end
	return table.concat(chars)
end

T.describe("filter: no filter", function()
	T.it("passes data through unchanged when /Filter is absent", function()
		local dict = { Length = 5 }
		local data, err = filter.decode_stream(dict, "hello")
		T.eq(err, nil)
		T.eq(data, "hello")
	end)
end)

T.describe("filter: FlateDecode", function()
	T.it("inflates FlateDecode data", function()
		local original = "hello world hello world hello world"
		local compressed, cerr = compress.deflate(original)
		if compressed == nil then error(cerr) end
		local dict = { Filter = { kind = "name", value = "FlateDecode" } }
		local data, err = filter.decode_stream(dict, compressed)
		T.eq(err, nil)
		T.eq(data, original)
	end)

	T.it("accepts /Filter as a one-element array", function()
		local original = "abc"
		local compressed, cerr = compress.deflate(original)
		if compressed == nil then error(cerr) end
		local dict = { Filter = { [1] = { kind = "name", value = "FlateDecode" } } }
		local data, err = filter.decode_stream(dict, compressed)
		T.eq(err, nil)
		T.eq(data, original)
	end)

	T.it("errors clearly on an unsupported filter name", function()
		local dict = { Filter = { kind = "name", value = "DCTDecode" } }
		local data, err = filter.decode_stream(dict, "whatever")
		T.ok(data == nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("filter: PNG predictor", function()
	--: (integer, string, integer) -> string
	-- Forward Up-filter (PNG filter type 2) rows of `row_bytes` length,
	-- one byte at a time, against the previous row (all-zero for the first).
	local function up_filter_rows(row_bytes, raw_rows_concat, row_count)
		local out_rows = {}
		local prior = string.rep("\0", row_bytes)
		for i = 1, row_count do
			local raw = raw_rows_concat:sub((i - 1) * row_bytes + 1, i * row_bytes)
			local out = { [1] = 2 } --[[: { [integer]: integer } ]]
			for x = 1, row_bytes do
				local r = byte_at(raw, x)
				local p = byte_at(prior, x)
				if r == nil or p == nil then error("fixture construction bug") end
				out[x + 1] = (r - p) % 256
			end
			out_rows[i] = bytes_to_string(out, row_bytes + 1)
			prior = raw
		end
		return table.concat(out_rows)
	end

	T.it("un-filters PNG Up-predictor (/Predictor 12) data", function()
		local row_bytes = 3
		local raw = string.char(1, 2, 3) .. string.char(4, 5, 6)
		local filtered = up_filter_rows(row_bytes, raw, 2)
		local compressed, cerr = compress.deflate(filtered)
		if compressed == nil then error(cerr) end
		local dict = {
			Filter = { kind = "name", value = "FlateDecode" },
			DecodeParms = { Predictor = 12, Columns = row_bytes },
		}
		local data, err = filter.decode_stream(dict, compressed)
		T.eq(err, nil)
		T.eq(data, raw)
	end)

	T.it("defaults to /Predictor 1 (no predictor) when /DecodeParms is absent", function()
		local dict = { Filter = { kind = "name", value = "FlateDecode" } }
		local compressed, cerr = compress.deflate("plain data")
		if compressed == nil then error(cerr) end
		local data, err = filter.decode_stream(dict, compressed)
		T.eq(err, nil)
		T.eq(data, "plain data")
	end)

	T.it("uses default_columns when /DecodeParms /Columns is absent", function()
		local row_bytes = 4
		local raw = string.char(10, 20, 30, 40)
		local filtered = up_filter_rows(row_bytes, raw, 1)
		local compressed, cerr = compress.deflate(filtered)
		if compressed == nil then error(cerr) end
		local dict = {
			Filter = { kind = "name", value = "FlateDecode" },
			DecodeParms = { Predictor = 12 },
		}
		local data, err = filter.decode_stream(dict, compressed, row_bytes)
		T.eq(err, nil)
		T.eq(data, raw)
	end)

	T.it("errors clearly on an unrecognized predictor value", function()
		local dict = { DecodeParms = { Predictor = 99 } }
		local data, err = filter.decode_stream(dict, "abcd")
		T.ok(data == nil)
		T.ok(err ~= nil)
	end)

	T.it("reads /Predictor from /DP as an alias for /DecodeParms", function()
		local row_bytes = 2
		local raw = string.char(7, 8)
		local filtered = up_filter_rows(row_bytes, raw, 1)
		local compressed, cerr = compress.deflate(filtered)
		if compressed == nil then error(cerr) end
		local dict = {
			Filter = { kind = "name", value = "FlateDecode" },
			DP = { Predictor = 12, Columns = row_bytes },
		}
		local data, err = filter.decode_stream(dict, compressed)
		T.eq(err, nil)
		T.eq(data, raw)
	end)
end)

T.describe("filter: TIFF predictor", function()
	--: (integer, integer, string, integer) -> string
	-- Forward TIFF horizontal-differencing filter: each row's byte at
	-- position x becomes (raw[x] - raw[x - colors]) mod 256 (0 for
	-- positions with no earlier same-component sample in the row).
	local function tiff_filter_rows(row_bytes, colors, raw_rows_concat, row_count)
		local out_rows = {}
		for i = 1, row_count do
			local raw = raw_rows_concat:sub((i - 1) * row_bytes + 1, i * row_bytes)
			local out = {} --[[: { [integer]: integer } ]]
			for x = 1, row_bytes do
				local r = byte_at(raw, x)
				if r == nil then error("fixture construction bug") end
				local left = 0
				if x > colors then
					local l = byte_at(raw, x - colors)
					if l == nil then error("fixture construction bug") end
					left = l
				end
				out[x] = (r - left) % 256
			end
			out_rows[i] = bytes_to_string(out, row_bytes)
		end
		return table.concat(out_rows)
	end

	T.it("un-filters single-component (/Colors 1) TIFF-predicted data", function()
		local row_bytes = 4
		local raw = string.char(10, 12, 15, 20) .. string.char(1, 1, 2, 3)
		local filtered = tiff_filter_rows(row_bytes, 1, raw, 2)
		local compressed, cerr = compress.deflate(filtered)
		if compressed == nil then error(cerr) end
		local dict = {
			Filter = { kind = "name", value = "FlateDecode" },
			DecodeParms = { Predictor = 2, Columns = row_bytes },
		}
		local data, err = filter.decode_stream(dict, compressed)
		T.eq(err, nil)
		T.eq(data, raw)
	end)

	T.it("un-filters multi-component (/Colors 3, e.g. RGB) TIFF-predicted data", function()
		-- Columns is in samples-per-component (pixels), not raw bytes;
		-- row_bytes = Columns * Colors.
		local columns = 2
		local colors = 3
		local row_bytes = columns * colors
		local raw = string.char(100, 150, 200, 110, 140, 210)
		local filtered = tiff_filter_rows(row_bytes, colors, raw, 1)
		local compressed, cerr = compress.deflate(filtered)
		if compressed == nil then error(cerr) end
		local dict = {
			Filter = { kind = "name", value = "FlateDecode" },
			DecodeParms = { Predictor = 2, Columns = columns, Colors = colors },
		}
		local data, err = filter.decode_stream(dict, compressed)
		T.eq(err, nil)
		T.eq(data, raw)
	end)

	T.it("errors clearly on a sub-byte /BitsPerComponent (documented gap)", function()
		local dict = { DecodeParms = { Predictor = 2, BitsPerComponent = 4 } }
		local data, err = filter.decode_stream(dict, "abcd")
		T.ok(data == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── ASCIIHexDecode ────────────────────────────────────────────────────────

T.describe("filter: ASCIIHexDecode", function()
	T.it("decodes hex pairs terminated by '>'", function()
		local dict = { Filter = { kind = "name", value = "ASCIIHexDecode" } }
		local data, err = filter.decode_stream(dict, "68656C6C6F>")
		T.eq(err, nil)
		T.eq(data, "hello")
	end)

	T.it("ignores embedded whitespace", function()
		local dict = { Filter = { kind = "name", value = "ASCIIHexDecode" } }
		local data, err = filter.decode_stream(dict, "68 65 6C 6C 6F >")
		T.eq(err, nil)
		T.eq(data, "hello")
	end)

	T.it("pads an odd trailing digit with an implicit 0 nibble", function()
		local dict = { Filter = { kind = "name", value = "ASCIIHexDecode" } }
		local data, err = filter.decode_stream(dict, "68656C6C6F6>") -- trailing '6' -> 0x60
		T.eq(err, nil)
		T.eq(data, "hello`")
	end)

	T.it("errors on an invalid hex digit", function()
		local dict = { Filter = { kind = "name", value = "ASCIIHexDecode" } }
		local data, err = filter.decode_stream(dict, "68zz>")
		T.ok(data == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── RunLengthDecode ───────────────────────────────────────────────────────

T.describe("filter: RunLengthDecode", function()
	T.it("decodes a literal run", function()
		local dict = { Filter = { kind = "name", value = "RunLengthDecode" } }
		local data, err = filter.decode_stream(dict, string.char(2) .. "abc")
		T.eq(err, nil)
		T.eq(data, "abc")
	end)

	T.it("decodes a repeat run", function()
		local dict = { Filter = { kind = "name", value = "RunLengthDecode" } }
		local data, err = filter.decode_stream(dict, string.char(253) .. "A")
		T.eq(err, nil)
		T.eq(data, "AAAA")
	end)

	T.it("stops at the EOD marker (128), ignoring anything after it", function()
		local dict = { Filter = { kind = "name", value = "RunLengthDecode" } }
		local data, err = filter.decode_stream(dict, string.char(1) .. "xy" .. string.char(128) .. "garbage")
		T.eq(err, nil)
		T.eq(data, "xy")
	end)

	T.it("concatenates multiple runs", function()
		local dict = { Filter = { kind = "name", value = "RunLengthDecode" } }
		local input = string.char(2) .. "abc" .. string.char(253) .. "Z" .. string.char(128)
		local data, err = filter.decode_stream(dict, input)
		T.eq(err, nil)
		T.eq(data, "abcZZZZ")
	end)

	T.it("errors on a truncated literal run", function()
		local dict = { Filter = { kind = "name", value = "RunLengthDecode" } }
		local data, err = filter.decode_stream(dict, string.char(10) .. "ab")
		T.ok(data == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── ASCII85Decode ─────────────────────────────────────────────────────────
-- `ascii85_encode` is a test-only inverse of the library's decoder, used to
-- build fixtures without hand-computing base-85 digits (error-prone to do
-- by hand and not worth the transcription risk) — a round-trip check, same
-- spirit as `lzw_encode` below. The 'z'-shorthand and empty-input cases are
-- asserted directly since they're spec facts, not computed values.

--: (string) -> string
local function ascii85_encode(data)
	local out = {} --[[: { [integer]: string } ]]
	local n = #data
	local i = 1
	while i <= n do
		local remaining = math.min(4, n - i + 1)
		local b1 = byte_at(data, i) or 0
		local b2 = remaining >= 2 and (byte_at(data, i + 1) or 0) or 0
		local b3 = remaining >= 3 and (byte_at(data, i + 2) or 0) or 0
		local b4 = remaining >= 4 and (byte_at(data, i + 3) or 0) or 0
		local v = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
		if remaining == 4 and v == 0 then
			out[#out + 1] = "z"
		else
			local digits = {} --[[: { [integer]: integer } ]]
			for k = 5, 1, -1 do
				digits[k] = v % 85
				v = math.floor(v / 85)
			end
			for k = 1, remaining + 1 do
				out[#out + 1] = string.char(digits[k] + 33)
			end
		end
		i = i + remaining
	end
	return table.concat(out)
end

T.describe("filter: ASCII85Decode", function()
	T.it("round-trips arbitrary data through encode/decode", function()
		local dict = { Filter = { kind = "name", value = "ASCII85Decode" } }
		local original = "The quick brown fox jumps over the lazy dog. 1234567890!"
		local encoded = ascii85_encode(original) .. "~>"
		local data, err = filter.decode_stream(dict, encoded)
		T.eq(err, nil)
		T.eq(data, original)
	end)

	T.it("round-trips data whose length isn't a multiple of 4", function()
		local dict = { Filter = { kind = "name", value = "ASCII85Decode" } }
		for len = 1, 9 do
			local original = string.rep("x", len)
			local encoded = ascii85_encode(original) .. "~>"
			local data, err = filter.decode_stream(dict, encoded)
			T.eq(err, nil)
			T.eq(data, original)
		end
	end)

	T.it("decodes the 'z' shorthand as four zero bytes", function()
		local dict = { Filter = { kind = "name", value = "ASCII85Decode" } }
		local data, err = filter.decode_stream(dict, "z~>")
		T.eq(err, nil)
		T.eq(data, "\0\0\0\0")
	end)

	T.it("stops at the '~>' EOD marker", function()
		local dict = { Filter = { kind = "name", value = "ASCII85Decode" } }
		local encoded = ascii85_encode("abcd") .. "~>garbage after EOD"
		local data, err = filter.decode_stream(dict, encoded)
		T.eq(err, nil)
		T.eq(data, "abcd")
	end)

	T.it("errors on a lone trailing byte in the final group", function()
		local dict = { Filter = { kind = "name", value = "ASCII85Decode" } }
		-- One valid base85 char in the final group has no valid completion.
		local data, err = filter.decode_stream(dict, "!~>")
		T.ok(data == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── LZWDecode ─────────────────────────────────────────────────────────────
-- `lzw_encode` mirrors the library decoder's exact code-width/EarlyChange
-- bookkeeping (`lzw_code_width_for_test`, a test-local duplicate of
-- filter.lua's private `lzw_code_width`) so encode/decode round-trip
-- exercises the same table-growth boundaries the decoder must handle —
-- same rationale as `ascii85_encode` above: hand-authoring correct LZW
-- bitstreams isn't a trustworthy way to build a fixture.

--: (integer, integer) -> integer
local function lzw_code_width_for_test(next_code, early_change)
	local n = next_code - 1
	if early_change == 1 then n = n + 1 end
	if n < 511 then return 9 end
	if n < 1023 then return 10 end
	if n < 2047 then return 11 end
	return 12
end

--: (string, integer) -> string
local function lzw_encode(data, early_change)
	local dict = {} --[[: { [string]: integer } ]]
	local next_code = 258 --: integer
	local code_width = 9 --: integer
	--: () -> nil
	local function reset()
		dict = {}
		for i = 0, 255 do dict[string.char(i)] = i end
		next_code = 258
		code_width = 9
	end
	reset()

	local bits = {} --[[: { [integer]: integer } ]]
	--: (integer, integer) -> nil
	local function write_code(code, width)
		for k = width - 1, 0, -1 do
			bits[#bits + 1] = math.floor(code / (2 ^ k)) % 2
		end
	end

	local w = ""
	local n = #data
	for i = 1, n do
		local c = string.sub(data, i, i)
		local wc = w .. c
		if dict[wc] ~= nil then
			w = wc
		else
			local w_code = dict[w]
			if w_code == nil then error("lzw_encode fixture-construction bug: dict[w] missing") end
			write_code(w_code, code_width)
			dict[wc] = next_code
			next_code = next_code + 1
			code_width = lzw_code_width_for_test(next_code, early_change)
			w = c
		end
	end
	if w ~= "" then
		local w_code = dict[w]
		if w_code == nil then error("lzw_encode fixture-construction bug: dict[w] missing") end
		write_code(w_code, code_width)
	end
	write_code(257, code_width) -- EOD

	while #bits % 8 ~= 0 do bits[#bits + 1] = 0 end
	local out = {} --[[: { [integer]: string } ]]
	for i = 1, #bits, 8 do
		local b = 0
		for k = 0, 7 do b = b * 2 + bits[i + k] end
		out[#out + 1] = string.char(b)
	end
	return table.concat(out)
end

T.describe("filter: LZWDecode", function()
	T.it("round-trips short data (EarlyChange 1, the PDF default)", function()
		local dict = { Filter = { kind = "name", value = "LZWDecode" } }
		local original = "hello hello hello hello world world world"
		local encoded = lzw_encode(original, 1)
		local data, err = filter.decode_stream(dict, encoded)
		T.eq(err, nil)
		T.eq(data, original)
	end)

	T.it("round-trips data long enough to cross the 9->10 bit code-width boundary", function()
		local dict = { Filter = { kind = "name", value = "LZWDecode" } }
		local parts = {}
		for i = 1, 400 do parts[i] = string.char(32 + (i % 90)) end
		local original = table.concat(parts)
		local encoded = lzw_encode(original, 1)
		local data, err = filter.decode_stream(dict, encoded)
		T.eq(err, nil)
		T.eq(data, original)
	end)

	T.it("round-trips with /DecodeParms /EarlyChange 0", function()
		local dict = {
			Filter = { kind = "name", value = "LZWDecode" },
			DecodeParms = { EarlyChange = 0 },
		}
		local original = "aaaaaaaaaa bbbbbbbbbb cccccccccc aaaaaaaaaa bbbbbbbbbb"
		local encoded = lzw_encode(original, 0)
		local data, err = filter.decode_stream(dict, encoded)
		T.eq(err, nil)
		T.eq(data, original)
	end)

	T.it("errors on an invalid code sequence", function()
		local dict = { Filter = { kind = "name", value = "LZWDecode" } }
		-- Code 300 as the very first 9-bit code: not a literal (>255), not
		-- Clear/EOD, and not yet in the dictionary (nothing decoded before it
		-- to extend) — an invalid sequence.
		local data, err = filter.decode_stream(dict, string.char(0x96, 0x00)) -- 300 in 9 bits, padded
		T.ok(data == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── Filter chains (/Filter as an array of >1 name) ───────────────────────
-- Applied in array order per ISO 32000-1 §7.4 / confirmed against pdf.js's
-- `Parser#filter` (`src/core/parser.js`): filterArray[0] is applied to the
-- raw stream bytes first, each subsequent filter wraps the previous
-- filter's output — i.e. array order is outermost (closest to the file's
-- raw bytes) to innermost (closest to the original content).

--: (integer, string, integer) -> string
-- Same forward Up-filter helper as "filter: PNG predictor"'s local
-- (duplicated here since that one is scoped to its own `describe` callback).
local function up_filter_rows_chain(row_bytes, raw_rows_concat, row_count)
	local out_rows = {}
	local prior = string.rep("\0", row_bytes)
	for i = 1, row_count do
		local raw = raw_rows_concat:sub((i - 1) * row_bytes + 1, i * row_bytes)
		local out = { [1] = 2 } --[[: { [integer]: integer } ]]
		for x = 1, row_bytes do
			local r = byte_at(raw, x)
			local p = byte_at(prior, x)
			if r == nil or p == nil then error("fixture construction bug") end
			out[x + 1] = (r - p) % 256
		end
		out_rows[i] = bytes_to_string(out, row_bytes + 1)
		prior = raw
	end
	return table.concat(out_rows)
end

T.describe("filter: filter chains", function()
	T.it("decodes an ASCIIHexDecode -> FlateDecode chain", function()
		-- Producer pipeline was: original -> deflate -> hex-encode (the
		-- outermost encoding, closest to the file's raw bytes, is hex).
		local original = "chained filter test data, chained filter test data"
		local compressed, cerr = compress.deflate(original)
		if compressed == nil then error(cerr) end
		local hex_chars = {}
		for i = 1, #compressed do
			hex_chars[#hex_chars + 1] = string.format("%02X", byte_at(compressed, i) or 0)
		end
		local hexed = table.concat(hex_chars) .. ">"

		local dict = {
			Filter = {
				[1] = { kind = "name", value = "ASCIIHexDecode" },
				[2] = { kind = "name", value = "FlateDecode" },
			},
		}
		local data, err = filter.decode_stream(dict, hexed)
		T.eq(err, nil)
		T.eq(data, original)
	end)

	T.it("applies each filter's own /DecodeParms element (predictor only on the Flate step)", function()
		local row_bytes = 3
		local raw = string.char(1, 2, 3, 4, 5, 6) -- two rows of 3 bytes
		local filtered = up_filter_rows_chain(row_bytes, raw, 2)
		local compressed, cerr = compress.deflate(filtered)
		if compressed == nil then error(cerr) end
		local hex_chars = {}
		for i = 1, #compressed do
			hex_chars[#hex_chars + 1] = string.format("%02X", byte_at(compressed, i) or 0)
		end
		local hexed = table.concat(hex_chars) .. ">"

		local dict = {
			Filter = {
				[1] = { kind = "name", value = "ASCIIHexDecode" },
				[2] = { kind = "name", value = "FlateDecode" },
			},
			DecodeParms = {
				-- index 1 (the hex step) intentionally absent: no parms for it.
				[2] = { Predictor = 12, Columns = row_bytes },
			},
		}
		local data, err = filter.decode_stream(dict, hexed)
		T.eq(err, nil)
		T.eq(data, raw)
	end)
end)

T.describe("filter: malformed input", function()
	T.it("errors when the stream dictionary isn't a table", function()
		local data, err = filter.decode_stream("not a dict", "abc")
		T.ok(data == nil)
		T.ok(err ~= nil)
	end)
end)
