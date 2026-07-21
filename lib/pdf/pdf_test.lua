-- lib/pdf/pdf_test.lua
-- End-to-end tests for lib/pdf's top-level document loader, tying together
-- lib/pdf/object.lua, lib/pdf/xref.lua, and lib/pdf/filter.lua.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local pdf = require("lib.pdf")

--: (unknown) -> { [string]: unknown, [integer]: unknown }
local function as_table(v)
	if type(v) ~= "table" then error("expected table, got " .. type(v)) end
	return v
end

--- Builds a minimal-but-complete single-revision PDF byte string with a
-- Catalog (object 1), a Pages tree (object 2), and one Page (object 3), plus
-- a valid traditional xref table + trailer. Object offsets are computed from
-- the actual concatenated text so the fixture can't silently drift.
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

T.describe("pdf: string_to_document", function()
	T.it("loads a minimal PDF and exposes its xref entries and trailer", function()
		local bytes = build_minimal_pdf()
		local doc, err = pdf.string_to_document(bytes)
		T.eq(err, nil)
		local d = as_table(doc)
		local entries = as_table(d.entries)
		T.eq(as_table(entries[1]).kind, "in_use")
		T.eq(as_table(entries[2]).kind, "in_use")
		T.eq(as_table(entries[3]).kind, "in_use")
		T.eq(as_table(d.trailer).Size, 4)
	end)

	T.it("errors on bytes with no xref structure at all", function()
		local doc, err = pdf.string_to_document("not a pdf file")
		T.ok(doc == nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("pdf: resolve_reference / resolve", function()
	T.it("resolves an indirect reference to its object's value", function()
		local doc = as_table(pdf.string_to_document(build_minimal_pdf()))
		local ref = { kind = "reference", num = 1, gen = 0 }
		local catalog, err = pdf.resolve_reference(doc, ref)
		T.eq(err, nil)
		local c = as_table(catalog)
		T.eq(as_table(c.Type).value, "Catalog")
	end)

	T.it("resolve() passes non-reference values through unchanged", function()
		local doc = as_table(pdf.string_to_document(build_minimal_pdf()))
		local v, err = pdf.resolve(doc, 42)
		T.eq(err, nil)
		T.eq(v, 42)
	end)

	T.it("resolve() follows a reference when given one", function()
		local doc = as_table(pdf.string_to_document(build_minimal_pdf()))
		local ref = { kind = "reference", num = 2, gen = 0 }
		local v = as_table(pdf.resolve(doc, ref))
		T.eq(as_table(v.Type).value, "Pages")
	end)

	T.it("follows a chain of references (Page -> Parent -> Pages)", function()
		local doc = as_table(pdf.string_to_document(build_minimal_pdf()))
		local page = as_table(pdf.resolve_reference(doc, { kind = "reference", num = 3, gen = 0 }))
		local parent = as_table(pdf.resolve(doc, page.Parent))
		T.eq(as_table(parent.Type).value, "Pages")
		local kids = as_table(parent.Kids)
		local kid1 = as_table(pdf.resolve(doc, kids[1]))
		T.eq(as_table(kid1.Type).value, "Page")
	end)

	T.it("errors when the referenced object number isn't in the xref table", function()
		local doc = as_table(pdf.string_to_document(build_minimal_pdf()))
		local v, err = pdf.resolve_reference(doc, { kind = "reference", num = 999, gen = 0 })
		T.ok(v == nil)
		T.ok(err ~= nil)
	end)

	T.it("errors clearly when resolving an object marked free", function()
		local doc = as_table(pdf.string_to_document(build_minimal_pdf()))
		local v, err = pdf.resolve_reference(doc, { kind = "reference", num = 0, gen = 65535 })
		T.ok(v == nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("pdf: document_root", function()
	T.it("resolves the trailer's /Root entry", function()
		local doc = as_table(pdf.string_to_document(build_minimal_pdf()))
		local root, err = pdf.document_root(doc)
		T.eq(err, nil)
		T.eq(as_table(as_table(root).Type).value, "Catalog")
	end)
end)

T.describe("pdf: stream_to_bytes", function()
	T.it("decodes a stream's data via lib/pdf/filter", function()
		local compress = require("lib.compress")
		local original = "stream contents here"
		local compressed, cerr = compress.deflate(original)
		if compressed == nil then error(cerr) end
		local stream = {
			kind = "stream",
			dict = { Filter = { kind = "name", value = "FlateDecode" } },
			data = compressed,
		}
		local data, err = pdf.stream_to_bytes(stream)
		T.eq(err, nil)
		T.eq(data, original)
	end)

	T.it("errors when given a non-stream object", function()
		local data, err = pdf.stream_to_bytes({ kind = "name", value = "X" })
		T.ok(data == nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("pdf: indirect /Length resolution end-to-end", function()
	T.it("resolves a stream whose /Length is itself an indirect reference", function()
		local header = "%PDF-1.4\n"
		-- Object 2 holds the Length (5) as a plain indirect integer object.
		local length_obj = "2 0 obj\n5\nendobj\n"
		local stream_data = "hello"
		local stream_obj = "1 0 obj\n<< /Length 2 0 R >>\nstream\n" .. stream_data .. "\nendstream\nendobj\n"

		local body = stream_obj .. length_obj
		local stream_offset = #header
		local length_offset = #header + #stream_obj

		local xref_text = "xref\n0 3\n0000000000 65535 f \n"
			.. string.format("%010d 00000 n \n", stream_offset)
			.. string.format("%010d 00000 n \n", length_offset)
		local trailer = "trailer\n<< /Size 3 /Root 1 0 R >>\n"
		local xref_offset = #header + #body
		local bytes = header .. body .. xref_text .. "\n" .. trailer .. "startxref\n" .. xref_offset .. "\n%%EOF"

		local doc = as_table(pdf.string_to_document(bytes))
		local obj = as_table(pdf.resolve_reference(doc, { kind = "reference", num = 1, gen = 0 }))
		T.eq(obj.kind, "stream")
		T.eq(obj.data, stream_data)
	end)
end)
