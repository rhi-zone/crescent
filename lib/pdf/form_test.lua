-- lib/pdf/form_test.lua
-- Tests for lib/pdf/form.lua: AcroForm field extraction and value filling.
-- Synthetic PDFs are hand-built (mirroring lib/pdf/pdf_test.lua's fixture
-- style) since these need an /AcroForm structure the shared-foundation
-- fixtures don't exercise.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local form = require("lib.pdf.form")
local pdf = require("lib.pdf")

--: (unknown) -> { [string]: unknown, [integer]: unknown }
local function as_table(v)
	if type(v) ~= "table" then error("expected table, got " .. type(v)) end
	return v
end

-- Loads a document, keeping its narrower `Document`-shaped return type
-- intact (bytes/entries/trailer as named fields) rather than degrading it
-- through `as_table`'s generic index-signature return — an index signature
-- doesn't guarantee any particular named field is present, so a value typed
-- that way doesn't structurally satisfy `form.document_to_fields`/
-- `form.fill_fields`'s `Document`-shaped parameter (confirmed: passing an
-- `as_table`-derived value to those specifically fails typecheck with
-- "missing field 'bytes'", even though the same pattern happens to pass
-- when calling `lib/pdf`'s own `resolve_reference`/`document_root` — an
-- inconsistency between the two, not something to rely on either way).
--: (string) -> { bytes: string, entries: unknown, trailer: unknown }
local function load_doc(bytes)
	local doc, err = pdf.string_to_document(bytes)
	if doc == nil then error(err) end
	return doc
end

--- Builds a single-revision PDF from a list of `"N 0 obj\n...\nendobj\n"`
-- bodies (index i is object number i), a /Root object number, and the total
-- object count (`/Size` = count + 1). Offsets are computed from the actual
-- concatenated text, same discipline as lib/pdf/pdf_test.lua's fixture.
--: ({ [integer]: string }, integer) -> string
local function build_pdf(objs, root_num)
	local header = "%PDF-1.4\n"
	local offsets = {} --[[: { [integer]: integer } ]]
	local body = ""
	local pos = #header
	for i = 1, #objs do
		offsets[i] = pos
		body = body .. objs[i]
		pos = pos + #objs[i]
	end
	local xref_offset = #header + #body

	local xref_lines = { "xref\n0 " .. (#objs + 1) .. "\n0000000000 65535 f \n" } --[[: { [integer]: string } ]]
	for i = 1, #objs do
		xref_lines[#xref_lines + 1] = string.format("%010d 00000 n \n", offsets[i])
	end
	local xref_text = table.concat(xref_lines)
	local trailer = "trailer\n<< /Size " .. (#objs + 1) .. " /Root " .. root_num .. " 0 R >>\n"

	return header .. body .. xref_text .. trailer .. "startxref\n" .. xref_offset .. "\n%%EOF"
end

-- ── Fixture 1: a single merged text field (Catalog=1, Pages=2, Page=3, ────
-- field+widget=4, AcroForm=5) ────────────────────────────────────────────────

--: () -> string
local function build_text_field_pdf()
	local objs = {
		"1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R >>\nendobj\n",
		"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
		"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>\nendobj\n",
		"4 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /V (John) /DV (N/A) /Rect [10 20 110 40] "
			.. "/P 3 0 R >>\nendobj\n",
		"5 0 obj\n<< /Fields [4 0 R] >>\nendobj\n",
	}
	return build_pdf(objs, 1)
end

T.describe("form: document_to_fields (single text field)", function()
	T.it("extracts name, type, value, default_value, rect, page", function()
		local doc = load_doc(build_text_field_pdf())
		local fields, err = form.document_to_fields(doc)
		T.eq(err, nil)
		if fields == nil then error("expected fields") end
		local fs = fields
		T.eq(#fs, 1)
		local f = as_table(fs[1])
		T.eq(f.name, "Name")
		T.eq(f.type, "text")
		T.eq(f.value, "John")
		T.eq(f.default_value, "N/A")
		T.eq(f.flags, 0)
		local rect = as_table(f.rect)
		T.eq(rect[1], 10)
		T.eq(rect[3], 110)
		local page = as_table(f.page)
		T.eq(page.kind, "reference")
		T.eq(page.num, 3)
	end)
end)

T.describe("form: fill_fields (text field)", function()
	T.it("fills the field's /V and the result is loadable with the new value", function()
		local doc = load_doc(build_text_field_pdf())
		local new_bytes, err = form.fill_fields(doc, { Name = "Alice" })
		T.eq(err, nil)
		if new_bytes == nil then error("expected new_bytes") end

		local doc2 = load_doc(new_bytes)
		local fields2 = as_table(form.document_to_fields(doc2)) --[[: { [integer]: unknown } ]]
		T.eq(as_table(fields2[1]).value, "Alice")
	end)

	T.it("errors on an unknown field name", function()
		local doc = load_doc(build_text_field_pdf())
		local new_bytes, err = form.fill_fields(doc, { Nope = "x" })
		T.ok(new_bytes == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── Fixture 2: a checkbox (merged field+widget, /AP /N inline) ─────────────

--: () -> string
local function build_checkbox_pdf()
	local objs = {
		"1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R >>\nendobj\n",
		"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
		"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>\nendobj\n",
		"4 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Btn /T (Agree) /V /Off /AS /Off /Rect [10 10 30 30] "
			.. "/P 3 0 R /AP << /N << /Yes 10 0 R /Off 11 0 R >> >> >>\nendobj\n",
		"5 0 obj\n<< /Fields [4 0 R] >>\nendobj\n",
	}
	return build_pdf(objs, 1)
end

T.describe("form: document_to_fields (checkbox)", function()
	T.it("reports type checkbox", function()
		local doc = load_doc(build_checkbox_pdf())
		local fields = as_table(form.document_to_fields(doc)) --[[: { [integer]: unknown } ]]
		T.eq(as_table(fields[1]).type, "checkbox")
	end)
end)

T.describe("form: fill_fields (checkbox)", function()
	T.it("checking it sets /V and /AS to the on-state name", function()
		local doc = load_doc(build_checkbox_pdf())
		local new_bytes, err = form.fill_fields(doc, { Agree = { kind = "name", value = "Yes" } })
		T.eq(err, nil)
		if new_bytes == nil then error("expected new_bytes") end

		local doc2 = load_doc(new_bytes)
		local widget = as_table(pdf.resolve_reference(doc2, { kind = "reference", num = 4, gen = 0 }))
		T.eq(as_table(widget.V).value, "Yes")
		T.eq(as_table(widget.AS).value, "Yes")
	end)

	T.it("a requested state the widget doesn't offer falls back to /AS Off", function()
		local doc = load_doc(build_checkbox_pdf())
		local new_bytes = form.fill_fields(doc, { Agree = { kind = "name", value = "Nonexistent" } })
		if new_bytes == nil then error("expected new_bytes") end
		local doc2 = load_doc(new_bytes)
		local widget = as_table(pdf.resolve_reference(doc2, { kind = "reference", num = 4, gen = 0 }))
		T.eq(as_table(widget.V).value, "Nonexistent")
		T.eq(as_table(widget.AS).value, "Off")
	end)
end)

-- ── Fixture 3: a radio button group (field=4 has Kids=[5,6], each a widget) ─

--: () -> string
local function build_radio_group_pdf()
	local objs = {
		"1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 7 0 R >>\nendobj\n",
		"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
		"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R] >>\nendobj\n",
		"4 0 obj\n<< /FT /Btn /Ff 32768 /T (Choice) /V /A /Kids [5 0 R 6 0 R] >>\nendobj\n",
		"5 0 obj\n<< /Type /Annot /Subtype /Widget /Parent 4 0 R /AS /A /Rect [0 0 10 10] /P 3 0 R "
			.. "/AP << /N << /A 20 0 R /Off 21 0 R >> >> >>\nendobj\n",
		"6 0 obj\n<< /Type /Annot /Subtype /Widget /Parent 4 0 R /AS /Off /Rect [20 0 30 10] /P 3 0 R "
			.. "/AP << /N << /B 22 0 R /Off 23 0 R >> >> >>\nendobj\n",
		"7 0 obj\n<< /Fields [4 0 R] >>\nendobj\n",
	}
	return build_pdf(objs, 1)
end

T.describe("form: document_to_fields (radio group)", function()
	T.it("reports one record per widget, sharing the field name/type/value", function()
		local doc = load_doc(build_radio_group_pdf())
		local fields = as_table(form.document_to_fields(doc)) --[[: { [integer]: unknown } ]]
		T.eq(#fields, 2)
		local f1 = as_table(fields[1])
		local f2 = as_table(fields[2])
		T.eq(f1.name, "Choice")
		T.eq(f2.name, "Choice")
		T.eq(f1.type, "radio")
		T.eq(as_table(f1.value).value, "A")
		T.eq(as_table(f2.value).value, "A")
		T.ok(f1.rect ~= f2.rect)
	end)
end)

T.describe("form: fill_fields (radio group)", function()
	T.it("selecting option B sets the field's /V and each widget's /AS accordingly", function()
		local doc = load_doc(build_radio_group_pdf())
		local new_bytes, err = form.fill_fields(doc, { Choice = { kind = "name", value = "B" } })
		T.eq(err, nil)
		if new_bytes == nil then error("expected new_bytes") end

		local doc2 = load_doc(new_bytes)
		local field = as_table(pdf.resolve_reference(doc2, { kind = "reference", num = 4, gen = 0 }))
		T.eq(as_table(field.V).value, "B")

		local widget1 = as_table(pdf.resolve_reference(doc2, { kind = "reference", num = 5, gen = 0 }))
		local widget2 = as_table(pdf.resolve_reference(doc2, { kind = "reference", num = 6, gen = 0 }))
		-- Widget 5 has no "B" appearance state -> falls back to Off.
		T.eq(as_table(widget1.AS).value, "Off")
		-- Widget 6 has a "B" state -> selected.
		T.eq(as_table(widget2.AS).value, "B")
	end)
end)
