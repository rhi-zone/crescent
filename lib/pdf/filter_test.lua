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
		local dict = { Filter = { kind = "name", value = "RunLengthDecode" } }
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

	T.it("errors clearly on the unimplemented TIFF predictor", function()
		local dict = { DecodeParms = { Predictor = 2 } }
		local data, err = filter.decode_stream(dict, "abcd")
		T.ok(data == nil)
		T.ok(err ~= nil)
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

T.describe("filter: malformed input", function()
	T.it("errors when the stream dictionary isn't a table", function()
		local data, err = filter.decode_stream("not a dict", "abc")
		T.ok(data == nil)
		T.ok(err ~= nil)
	end)
end)
