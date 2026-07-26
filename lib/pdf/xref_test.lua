-- lib/pdf/xref_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local xref = require("lib.pdf.xref")
local compress = require("lib.compress")

--: (unknown) -> { [string]: unknown, [integer]: unknown }
local function as_table(v)
	if type(v) ~= "table" then error("expected table, got " .. type(v)) end
	return v
end

-- ── Traditional xref tables ──────────────────────────────────────────────────

T.describe("xref: traditional table", function()
	T.it("parses a simple single-subsection table", function()
		local src = "xref\n"
			.. "0 3\n"
			.. "0000000000 65535 f \n"
			.. "0000000010 00000 n \n"
			.. "0000000079 00000 n \n"
			.. "trailer\n"
			.. "<< /Size 3 /Root 2 0 R >>\n"
		local section, err = xref.parse_traditional(src, 1)
		T.eq(err, nil)
		local s = as_table(section)
		local entries = as_table(s.entries)
		T.eq(as_table(entries[0]).kind, "free")
		T.eq(as_table(entries[1]).kind, "in_use")
		T.eq(as_table(entries[1]).offset, 10)
		T.eq(as_table(entries[2]).kind, "in_use")
		T.eq(as_table(entries[2]).offset, 79)
		T.eq(as_table(s.trailer).Size, 3)
	end)

	T.it("parses multiple subsections", function()
		local src = "xref\n"
			.. "0 1\n"
			.. "0000000000 65535 f \n"
			.. "3 2\n"
			.. "0000000100 00000 n \n"
			.. "0000000200 00000 n \n"
			.. "trailer\n"
			.. "<< /Size 5 >>\n"
		local section = as_table(xref.parse_traditional(src, 1))
		local entries = as_table(section.entries)
		T.eq(as_table(entries[3]).offset, 100)
		T.eq(as_table(entries[4]).offset, 200)
		T.eq(entries[1], nil)
	end)

	T.it("extracts /Prev and /XRefStm from the trailer", function()
		local src = "xref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 1 /Prev 500 /XRefStm 600 >>\n"
		local section = as_table(xref.parse_traditional(src, 1))
		T.eq(section.prev, 500)
		T.eq(section.xref_stm, 600)
	end)

	T.it("errors when 'xref' keyword is missing", function()
		local section, err = xref.parse_traditional("not xref data", 1)
		T.ok(section == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── Top-level build(): startxref + full chain ────────────────────────────────

T.describe("xref: build()", function()
	T.it("locates startxref and builds the table", function()
		local prefix = "1 0 obj\n<< /Type /Catalog >>\nendobj\n"
		local xref_text = "xref\n0 2\n0000000000 65535 f \n0000000009 00000 n \ntrailer\n<< /Size 2 /Root 1 0 R >>\n"
		local bytes = prefix .. xref_text .. "startxref\n" .. #prefix .. "\n%%EOF"
		local t, err = xref.build(bytes)
		T.eq(err, nil)
		local tt = as_table(t)
		local entries = as_table(tt.entries)
		T.eq(as_table(entries[1]).offset, 9)
		T.eq(as_table(tt.trailer).Size, 2)
	end)

	T.it("uses the last startxref when more than one is present", function()
		local xref_text = "xref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 1 >>\n"
		-- A bogus early "startxref" (e.g. inside a string object) must be ignored.
		local bytes = "(startxref fake) " .. xref_text .. "startxref\n17\n%%EOF"
		local offset, err = xref.find_startxref(bytes)
		T.eq(err, nil)
		T.eq(offset, 17)
	end)

	T.it("errors when 'startxref' is entirely absent", function()
		local t, err = xref.build("no xref keyword anywhere here")
		T.ok(t == nil)
		T.ok(err ~= nil)
	end)

	T.it("follows a /Prev chain, newest section winning", function()
		-- Older section (offset 0): object 1 at offset 111.
		local old_xref = "xref\n1 1\n0000000111 00000 n \ntrailer\n<< /Size 2 >>\n"
		local old_offset = 0
		-- Newer section: object 1 at offset 222 (overrides), object 2 new.
		local new_xref_start = #old_xref
		local new_xref = "xref\n1 2\n0000000222 00000 n \n0000000333 00000 n \ntrailer\n<< /Size 3 /Prev "
			.. old_offset .. " >>\n"
		local bytes = old_xref .. new_xref .. "startxref\n" .. new_xref_start .. "\n%%EOF"
		local t = as_table(xref.build(bytes))
		local entries = as_table(t.entries)
		T.eq(as_table(entries[1]).offset, 222) -- newest wins, not overwritten by older
		T.eq(as_table(entries[2]).offset, 333)
	end)

	T.it("stops instead of looping forever on a cyclical /Prev chain", function()
		local xref_text = "xref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 1 /Prev 0 >>\n"
		local bytes = xref_text .. "startxref\n0\n%%EOF"
		local t, err = xref.build(bytes)
		T.eq(err, nil) -- cycle guard breaks the loop cleanly rather than erroring
		T.ok(t ~= nil)
	end)
end)

-- ── Cross-reference streams ──────────────────────────────────────────────────

-- Same string.byte-overload-in-loop gap recorded in TODO.md for
-- lib/pdf/xref.lua: wrap it in a local single-signature function.
--: (string, integer) -> integer | nil
local function byte_at(s, pos)
	return string.byte(s, pos)
end

-- Builds a string one byte at a time via string.char + table.concat rather
-- than string.char(unpack(bytes)) — `unpack`'s generic <V> return type
-- failed to resolve to `...integer` even at this file's single call site
-- (`return unpack(t, 1, n)` from a `({ [integer]: integer, ... }, integer)
-- -> (...integer)`-annotated wrapper reported "cannot return `..._` against
-- variadic `...integer`"), a distinct instance of the generic-instantiation
-- substrate gap already tracked in TODO.md. Not worth its own entry given
-- the existing ones cover the same class; this file just avoids `unpack`.
--: ({ [integer]: integer }, integer) -> string
local function bytes_to_string(t, n)
	local chars = {}
	for i = 1, n do chars[i] = string.char(t[i]) end
	return table.concat(chars)
end

--: (integer, integer) -> string
-- Big-endian encode `v` into `width` bytes.
local function be(v, width)
	local bytes = {} --[[: { [integer]: integer } ]]
	for i = width, 1, -1 do
		bytes[i] = v % 256
		v = math.floor(v / 256)
	end
	return bytes_to_string(bytes, width)
end

--: ({ [integer]: { [integer]: integer } }, integer, integer, integer) -> string
local function build_rows(rows, w1, w2, w3)
	local parts = {}
	for i = 1, #rows do
		local row = rows[i]
		parts[#parts + 1] = be(row[1], w1) .. be(row[2], w2) .. be(row[3], w3)
	end
	return table.concat(parts)
end

T.describe("xref: cross-reference streams", function()
	T.it("decodes an uncompressed xref stream", function()
		local rows = { { 0, 0, 65535 }, { 1, 10, 0 }, { 1, 79, 0 } }
		local data = build_rows(rows, 1, 2, 1)
		local dict_src = "<< /Type /XRef /W [1 2 1] /Size 3 /Length " .. #data .. " >>"
		local src = "5 0 obj\n" .. dict_src .. "\nstream\n" .. data .. "\nendstream\nendobj"
		local pdf_object = require("lib.pdf.object")
		local indirect = as_table(pdf_object.string_to_indirect_object(src))
		local entries, trailer, prev, err = xref.decode_xref_stream(indirect.value)
		T.eq(err, nil)
		local e = entries --[[: { [integer]: unknown } ]]
		T.eq(as_table(e[0]).kind, "free")
		T.eq(as_table(e[1]).kind, "in_use")
		T.eq(as_table(e[1]).offset, 10)
		T.eq(as_table(e[2]).offset, 79)
		T.eq(as_table(trailer).Size, 3)
		T.eq(prev, nil)
	end)

	T.it("decodes a FlateDecode-compressed xref stream", function()
		local rows = { { 1, 100, 0 }, { 1, 200, 0 } }
		local data = build_rows(rows, 1, 4, 1)
		local compressed, cerr = compress.deflate(data)
		if compressed == nil then error(cerr) end
		local dict_src = "<< /Type /XRef /W [1 4 1] /Size 2 /Index [10 2] /Filter /FlateDecode /Length "
			.. #compressed .. " >>"
		local src = "9 0 obj\n" .. dict_src .. "\nstream\n" .. compressed .. "\nendstream\nendobj"
		local pdf_object = require("lib.pdf.object")
		local indirect = as_table(pdf_object.string_to_indirect_object(src))
		local entries, _, _, err = xref.decode_xref_stream(indirect.value)
		T.eq(err, nil)
		local e = entries --[[: { [integer]: unknown } ]]
		T.eq(as_table(e[10]).offset, 100)
		T.eq(as_table(e[11]).offset, 200)
	end)

	T.it("represents type-2 (compressed-in-ObjStm) entries without resolving them", function()
		local rows = { { 2, 7, 3 } } -- object stored in ObjStm object 7, index 3
		local data = build_rows(rows, 1, 2, 1)
		local dict_src = "<< /Type /XRef /W [1 2 1] /Index [50 1] /Size 51 /Length " .. #data .. " >>"
		local src = "1 0 obj\n" .. dict_src .. "\nstream\n" .. data .. "\nendstream\nendobj"
		local pdf_object = require("lib.pdf.object")
		local indirect = as_table(pdf_object.string_to_indirect_object(src))
		local entries = as_table((xref.decode_xref_stream(indirect.value)))
		local e50 = as_table(entries[50])
		T.eq(e50.kind, "compressed")
		T.eq(e50.stream_num, 7)
		T.eq(e50.index, 3)
	end)

	T.it("applies PNG Up-predictor un-filtering (/Predictor 12)", function()
		-- Two rows, 4 bytes each (w1=1,w2=2,w3=1). Up-filter each row against
		-- the previous (all-zero for the first row), forward-encoding by hand
		-- to build a fixture the decoder must correctly reverse.
		local row_bytes = 4
		local rows_raw = { be(1, 1) .. be(10, 2) .. be(0, 1), be(1, 1) .. be(11, 2) .. be(0, 1) }
		local filtered = {}
		local prior = string.rep("\0", row_bytes)
		for i = 1, #rows_raw do
			local raw = rows_raw[i]
			local out = { [1] = 2 } --[[: { [integer]: integer } ]] -- filter type 2 = Up
			for x = 1, row_bytes do
				local r = byte_at(raw, x)
				local p = byte_at(prior, x)
				if r == nil or p == nil then error("fixture construction bug") end
				out[#out + 1] = (r - p) % 256
			end
			filtered[#filtered + 1] = bytes_to_string(out, row_bytes + 1)
			prior = raw
		end
		local data = table.concat(filtered)
		local compressed, cerr = compress.deflate(data)
		if compressed == nil then error(cerr) end
		local dict_src = "<< /Type /XRef /W [1 2 1] /Size 2 /Filter /FlateDecode "
			.. "/DecodeParms << /Predictor 12 /Columns 4 >> /Length " .. #compressed .. " >>"
		local src = "1 0 obj\n" .. dict_src .. "\nstream\n" .. compressed .. "\nendstream\nendobj"
		local pdf_object = require("lib.pdf.object")
		local indirect = as_table(pdf_object.string_to_indirect_object(src))
		local entries, _, _, err = xref.decode_xref_stream(indirect.value)
		T.eq(err, nil)
		local e = entries --[[: { [integer]: unknown } ]]
		T.eq(as_table(e[0]).offset, 10)
		T.eq(as_table(e[1]).offset, 11)
	end)

	T.it("errors clearly on an unsupported filter", function()
		local dict_src = "<< /Type /XRef /W [1 2 1] /Size 1 /Filter /DCTDecode /Length 4 >>"
		local src = "1 0 obj\n" .. dict_src .. "\nstream\nabcd\nendstream\nendobj"
		local pdf_object = require("lib.pdf.object")
		local indirect = as_table(pdf_object.string_to_indirect_object(src))
		local entries, _, _, err = xref.decode_xref_stream(indirect.value)
		T.ok(entries == nil)
		T.ok(err ~= nil)
	end)

	T.it("errors clearly on the unimplemented TIFF predictor", function()
		local data = build_rows({ { 1, 5, 0 } }, 1, 2, 1)
		local dict_src = "<< /Type /XRef /W [1 2 1] /Size 1 /DecodeParms << /Predictor 2 >> /Length "
			.. #data .. " >>"
		local src = "1 0 obj\n" .. dict_src .. "\nstream\n" .. data .. "\nendstream\nendobj"
		local pdf_object = require("lib.pdf.object")
		local indirect = as_table(pdf_object.string_to_indirect_object(src))
		local entries, _, _, err = xref.decode_xref_stream(indirect.value)
		T.ok(entries == nil)
		T.ok(err ~= nil)
	end)

	T.it("errors when /W is missing", function()
		local src = "1 0 obj\n<< /Type /XRef /Size 1 /Length 0 >>\nstream\n\nendstream\nendobj"
		local pdf_object = require("lib.pdf.object")
		local indirect = as_table(pdf_object.string_to_indirect_object(src))
		local entries, _, _, err = xref.decode_xref_stream(indirect.value)
		T.ok(entries == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── Hybrid-reference files (/XRefStm) ────────────────────────────────────────

T.describe("xref: hybrid /XRefStm", function()
	T.it("merges entries from a hybrid xref stream pointed to by the trailer", function()
		local rows = { { 1, 999, 0 } }
		local data = build_rows(rows, 1, 2, 1)
		local stream_dict = "<< /Type /XRef /W [1 2 1] /Index [5 1] /Size 6 /Length " .. #data .. " >>"
		local stream_obj = "2 0 obj\n" .. stream_dict .. "\nstream\n" .. data .. "\nendstream\nendobj\n"
		local stream_offset = 0

		local classic = "xref\n0 1\n0000000000 65535 f \n"
			.. "trailer\n<< /Size 6 /Root 1 0 R /XRefStm " .. stream_offset .. " >>\n"
		local classic_offset = #stream_obj

		local bytes = stream_obj .. classic .. "startxref\n" .. classic_offset .. "\n%%EOF"
		local t, err = xref.build(bytes)
		T.eq(err, nil)
		local tt = as_table(t)
		local entries = as_table(tt.entries)
		T.eq(as_table(entries[0]).kind, "free") -- from the classic table
		T.eq(as_table(entries[5]).offset, 999) -- merged in from the hybrid stream
	end)
end)
