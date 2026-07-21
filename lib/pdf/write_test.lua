-- lib/pdf/write_test.lua
-- Tests for lib/pdf/write.lua: object serialization and incremental updates,
-- round-tripped through lib/pdf/object.lua's parser and lib/pdf's document
-- loader so a written file is verified by actually reading it back.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local write = require("lib.pdf.write")
local pdf_object = require("lib.pdf.object")
local pdf = require("lib.pdf")

--: (unknown) -> { [string]: unknown, [integer]: unknown }
local function as_table(v)
	if type(v) ~= "table" then error("expected table, got " .. type(v)) end
	return v
end

-- Round-trips a value through object_to_bytes then back through
-- lib/pdf/object.lua's parser, returning what was parsed back.
--: (unknown) -> unknown
local function roundtrip(v)
	local bytes, err = write.object_to_bytes(v)
	if bytes == nil then error(err) end
	local parsed, perr = pdf_object.string_to_object(bytes)
	if parsed == nil then error(perr) end
	return parsed
end

T.describe("write: object_to_bytes scalars", function()
	T.it("serializes booleans", function()
		T.eq(write.object_to_bytes(true), "true")
		T.eq(write.object_to_bytes(false), "false")
	end)

	T.it("serializes null", function()
		T.eq(write.object_to_bytes(pdf.null), "null")
	end)

	T.it("serializes integers without a decimal point", function()
		T.eq(write.object_to_bytes(42), "42")
		T.eq(write.object_to_bytes(-7), "-7")
		T.eq(write.object_to_bytes(0), "0")
	end)

	T.it("serializes reals, trimming trailing zeros", function()
		T.eq(write.object_to_bytes(1.5), "1.5")
		T.eq(write.object_to_bytes(0.25), "0.25")
	end)

	T.it("round-trips a real through the parser", function()
		T.eq(roundtrip(3.25), 3.25)
	end)
end)

T.describe("write: name serialization", function()
	T.it("serializes a plain name", function()
		T.eq(write.object_to_bytes({ kind = "name", value = "Foo" }), "/Foo")
	end)

	T.it("escapes irregular bytes as #xx", function()
		local bytes = write.object_to_bytes({ kind = "name", value = "A B#C" })
		T.eq(bytes, "/A#20B#23C")
	end)

	T.it("round-trips a name with irregular characters", function()
		local parsed = as_table(roundtrip({ kind = "name", value = "A B/C" }))
		T.eq(parsed.kind, "name")
		T.eq(parsed.value, "A B/C")
	end)
end)

T.describe("write: string serialization", function()
	T.it("serializes as a hex string", function()
		T.eq(write.object_to_bytes("AB"), "<4142>")
	end)

	T.it("round-trips arbitrary bytes, including delimiters and control bytes", function()
		local s = "(hello)\\world\r\n\0binary"
		T.eq(roundtrip(s), s)
	end)
end)

T.describe("write: reference serialization", function()
	T.it("serializes N G R", function()
		T.eq(write.object_to_bytes({ kind = "reference", num = 5, gen = 0 }), "5 0 R")
	end)

	T.it("round-trips a reference", function()
		local parsed = as_table(roundtrip({ kind = "reference", num = 12, gen = 3 }))
		T.eq(parsed.kind, "reference")
		T.eq(parsed.num, 12)
		T.eq(parsed.gen, 3)
	end)
end)

T.describe("write: array and dictionary serialization", function()
	T.it("round-trips an array of mixed object types", function()
		local arr = { 1, "AB", { kind = "name", value = "X" }, true, pdf.null }
		local parsed = as_table(roundtrip(arr))
		T.eq(parsed[1], 1)
		T.eq(parsed[2], "AB")
		T.eq(as_table(parsed[3]).value, "X")
		T.eq(parsed[4], true)
		T.eq(as_table(parsed[5]).kind, "null")
	end)

	T.it("round-trips a dictionary", function()
		local dict = { Type = { kind = "name", value = "Page" }, Count = 3 }
		local parsed = as_table(roundtrip(dict))
		T.eq(as_table(parsed.Type).value, "Page")
		T.eq(parsed.Count, 3)
	end)

	T.it("round-trips a nested array-of-dictionaries", function()
		local dict = { Kids = { { kind = "reference", num = 1, gen = 0 }, { kind = "reference", num = 2, gen = 0 } } }
		local parsed = as_table(roundtrip(dict))
		local kids = as_table(parsed.Kids)
		T.eq(as_table(kids[1]).num, 1)
		T.eq(as_table(kids[2]).num, 2)
	end)
end)

T.describe("write: stream serialization", function()
	T.it("serializes a stream with a correct /Length, ignoring a stale one", function()
		local stream = { kind = "stream", dict = { Length = 999 }, data = "hello" }
		local bytes, err = write.object_to_bytes(stream)
		T.eq(err, nil)
		if bytes == nil then error("expected bytes") end
		local b = bytes
		T.ok(b:find("/Length 5", 1, true) ~= nil)
		T.ok(b:find("stream\nhello\nendstream", 1, true) ~= nil)
	end)

	T.it("round-trips a stream's data", function()
		local stream = { kind = "stream", dict = {}, data = "some stream bytes" }
		local parsed = as_table(roundtrip(stream))
		T.eq(parsed.kind, "stream")
		T.eq(parsed.data, "some stream bytes")
	end)
end)

T.describe("write: indirect_object_to_bytes", function()
	T.it("serializes num gen obj ... endobj", function()
		local bytes, err = write.indirect_object_to_bytes({ num = 3, gen = 0, value = 42 })
		T.eq(err, nil)
		T.eq(bytes, "3 0 obj\n42\nendobj\n")
	end)

	T.it("round-trips through string_to_indirect_object", function()
		local bytes = write.indirect_object_to_bytes({ num = 7, gen = 0, value = { kind = "name", value = "X" } })
		if bytes == nil then error("expected bytes") end
		local indirect, err = pdf_object.string_to_indirect_object(bytes)
		T.eq(err, nil)
		local iv = as_table(indirect)
		T.eq(iv.num, 7)
		T.eq(as_table(iv.value).value, "X")
	end)
end)

-- ── Incremental update, end-to-end through lib/pdf's loader ────────────────

--: () -> string
local function build_minimal_pdf()
	local header = "%PDF-1.4\n"
	local objs = {
		"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
		"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
		"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n",
	}
	local offsets = {} --[[: { [integer]: integer } ]]
	local body = ""
	local pos = #header
	for i = 1, #objs do
		offsets[i] = pos
		body = body .. objs[i]
		pos = pos + #objs[i]
	end
	local xref_offset = #header + #body

	local xref_lines = { "xref\n0 4\n0000000000 65535 f \n" } --[[: { [integer]: string } ]]
	for i = 1, 3 do
		xref_lines[#xref_lines + 1] = string.format("%010d 00000 n \n", offsets[i])
	end
	local xref_text = table.concat(xref_lines)
	local trailer = "trailer\n<< /Size 4 /Root 1 0 R >>\n"

	return header .. body .. xref_text .. trailer .. "startxref\n" .. xref_offset .. "\n%%EOF"
end

T.describe("write: write_incremental_update", function()
	T.it("appends a new object and the result is loadable and resolves the new object", function()
		local doc = as_table(pdf.string_to_document(build_minimal_pdf()))
		local new_bytes, err = write.write_incremental_update(doc, {
			{ num = 4, gen = 0, value = { kind = "name", value = "Hello" } },
		})
		T.eq(err, nil)
		if new_bytes == nil then error("expected new_bytes") end

		local doc2 = as_table(pdf.string_to_document(new_bytes))
		local v, rerr = pdf.resolve_reference(doc2, { kind = "reference", num = 4, gen = 0 })
		T.eq(rerr, nil)
		T.eq(as_table(v).value, "Hello")

		-- Original objects still resolve too — the update chains via /Prev,
		-- it doesn't discard the original xref.
		local root, rooterr = pdf.document_root(doc2)
		T.eq(rooterr, nil)
		T.eq(as_table(as_table(root).Type).value, "Catalog")
	end)

	T.it("overwriting an existing object number makes it resolve to the new value", function()
		local doc = as_table(pdf.string_to_document(build_minimal_pdf()))
		local new_bytes = write.write_incremental_update(doc, {
			{ num = 3, gen = 0, value = { Type = { kind = "name", value = "Page" }, MediaBox = { 0, 0, 999, 999 } } },
		})
		if new_bytes == nil then error("expected new_bytes") end
		local doc2 = as_table(pdf.string_to_document(new_bytes))
		local page = as_table(pdf.resolve_reference(doc2, { kind = "reference", num = 3, gen = 0 }))
		local mediabox = as_table(page.MediaBox)
		T.eq(mediabox[3], 999)
	end)

	T.it("errors when given no objects to write", function()
		local doc = as_table(pdf.string_to_document(build_minimal_pdf()))
		local new_bytes, err = write.write_incremental_update(doc, {})
		T.ok(new_bytes == nil)
		T.ok(err ~= nil)
	end)
end)
