-- lib/pdf/text_test.lua
-- Tests for lib/pdf/text.lua: page/document text extraction and
-- reading-order reconstruction.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local pdf = require("lib.pdf")
local text = require("lib.pdf.text")

-- Mirrors lib/pdf/init.lua's Document shape (same-shape local
-- redeclaration, per the pattern lib/pdf/{font,text}.lua already use).
--:: Document = { bytes: string, entries: unknown, trailer: unknown }

--: (unknown) -> Document
-- NOTE: deliberately narrows via a direct `type(v) == "table"` check
-- rather than routing through a generic `(unknown) -> { [string]: unknown,
-- [integer]: unknown }` helper — that intermediate index-signature type is
-- itself a concrete structural type, and is NOT assignable to a specific
-- record type like Document (it lacks any evidence the named fields
-- exist), so passing it into pdf.resolve_reference/text.page_to_text
-- (which expect Document) fails to typecheck even though the underlying
-- runtime value is fine. Casting directly from a bare `type()`-narrowed
-- table is what this typechecker accepts for exactly this situation (see
-- lib/pdf/font_test.lua's `as_font` and lib/pdf/font.lua's `as_font`,
-- established during this same implementation).
local function as_document(v)
	if type(v) ~= "table" then error("expected a document, got " .. type(v)) end
	local d = v --[[: Document]]
	return d
end

--: (unknown) -> { [string]: unknown, [integer]: unknown }
-- For genuinely-`unknown` PDF object values (dict/array contents) — NOT
-- for values with a richer known shape (Document, Font, Span, page_to_text
-- results, ...), which must be narrowed via their own dedicated `as_*`
-- helper instead (see as_document above for why).
local function as_table(v)
	if type(v) ~= "table" then error("expected table, got " .. type(v)) end
	return v
end

--- Builds a PDF byte string from an ordered array of already-numbered
-- object bodies (each "N 0 obj\n...\nendobj\n", object 1 must be the
-- Catalog referenced by the trailer's /Root). Mirrors
-- lib/pdf/pdf_test.lua's build_minimal_pdf, generalized to N objects so
-- this file's fixture (multiple fonts + a content stream) can compute
-- real byte offsets without drifting.
--: ({ [integer]: string }) -> string
local function build_pdf(objs)
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

	local n = #objs
	local xref_lines = { "xref\n0 " .. (n + 1) .. "\n0000000000 65535 f \n" } --[[: { [integer]: string } ]]
	for i = 1, n do
		xref_lines[#xref_lines + 1] = string.format("%010d 00000 n \n", offsets[i])
	end
	local xref_text = table.concat(xref_lines)
	local trailer = "trailer\n<< /Size " .. (n + 1) .. " /Root 1 0 R >>\n"

	return header .. body .. xref_text .. trailer .. "startxref\n" .. xref_offset .. "\n%%EOF"
end

--: (integer, string) -> string
local function stream_obj(num, data)
	return num .. " 0 obj\n<< /Length " .. #data .. " >>\nstream\n" .. data .. "\nendstream\nendobj\n"
end

-- Object numbering: 1=Catalog 2=Pages 3=Page 4=Contents 5=F1(Standard)
-- 6=F2(WinAnsi) 7=F3(Differences) 8=F4(ToUnicode) 9=F4's ToUnicode CMap.
--: () -> string
local function build_fixture()
	local content = table.concat({
		"BT /F1 12 Tf 100 700 Td (Hi) Tj ET\n",
		"BT /F1 12 Tf 300 700 Td (World) Tj ET\n",
		"BT /F2 12 Tf 100 650 Td <80> Tj ET\n",
		"BT /F3 12 Tf 100 600 Td (A) Tj ET\n",
		"BT /F4 12 Tf 100 550 Td (Z) Tj ET\n",
		"BT /F1 12 Tf 100 500 Td [(He) -250 (llo)] TJ ET\n",
	})
	local tounicode_cmap = "1 beginbfchar\n<5A> <0051>\nendbfchar\n"

	local objs = {
		[1] = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
		[2] = "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
		[3] = "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
			.. "/Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R /F4 8 0 R >> >> "
			.. "/Contents 4 0 R >>\nendobj\n",
		[4] = stream_obj(4, content),
		[5] = "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
		[6] = "6 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
			.. "/Encoding /WinAnsiEncoding >>\nendobj\n",
		[7] = "7 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
			.. "/Encoding << /BaseEncoding /WinAnsiEncoding /Differences [65 /Euro] >> >>\nendobj\n",
		[8] = "8 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
			.. "/ToUnicode 9 0 R >>\nendobj\n",
		[9] = stream_obj(9, tounicode_cmap),
	}
	return build_pdf(objs)
end

--: () -> Document
local function fixture_doc()
	return as_document(pdf.string_to_document(build_fixture()))
end

--: (Document) -> unknown
local function fixture_page(doc)
	return pdf.resolve_reference(doc, { kind = "reference", num = 3, gen = 0 })
end

--: ({ [integer]: unknown }, string) -> unknown
local function find_span_with_text(spans, needle)
	local i = 1
	while spans[i] ~= nil do
		local s = as_table(spans[i])
		if s.text == needle then return s end
		i = i + 1
	end
	return nil
end

T.describe("text: page_to_text over a multi-font, multi-line page", function()
	T.it("extracts Tj text with the default StandardEncoding font", function()
		local doc = fixture_doc()
		local result, err = text.page_to_text(doc, fixture_page(doc))
		T.eq(err, nil)
		if result == nil then error("expected a result") end
		local hi = as_table(find_span_with_text(result.spans, "Hi"))
		T.eq(hi.x, 100)
		T.eq(hi.y, 700)
		T.eq(hi.font_name, "F1")
	end)

	T.it("extracts a WinAnsiEncoding Euro sign via a hex-string operand", function()
		local doc = fixture_doc()
		local result = text.page_to_text(doc, fixture_page(doc))
		if result == nil then error("expected a result") end
		local euro = as_table(find_span_with_text(result.spans, "\226\130\172"))
		T.ok(euro ~= nil)
		T.eq(euro.font_name, "F2")
	end)

	T.it("extracts a /Differences-remapped code (WinAnsi base + code 65 -> Euro)", function()
		local doc = fixture_doc()
		local result = text.page_to_text(doc, fixture_page(doc))
		if result == nil then error("expected a result") end
		-- F3 shows code 65 ('A'), which /Differences remaps to /Euro.
		local euro_spans = 0
		local i = 1
		while result.spans[i] ~= nil do
			local s = as_table(result.spans[i])
			if s.font_name == "F3" and s.text == "\226\130\172" then euro_spans = euro_spans + 1 end
			i = i + 1
		end
		T.eq(euro_spans, 1)
	end)

	T.it("a /ToUnicode CMap overrides the base encoding", function()
		local doc = fixture_doc()
		local result = text.page_to_text(doc, fixture_page(doc))
		if result == nil then error("expected a result") end
		-- F4 shows code 'Z' (90), overridden by its ToUnicode CMap to "Q".
		local q_span = find_span_with_text(result.spans, "Q")
		T.ok(q_span ~= nil)
	end)

	T.it("TJ array pieces concatenate into one span's decoded text", function()
		local doc = fixture_doc()
		local result = text.page_to_text(doc, fixture_page(doc))
		if result == nil then error("expected a result") end
		local hello = find_span_with_text(result.spans, "Hello")
		T.ok(hello ~= nil)
	end)

	T.it("reading order groups same-line spans and sorts left to right", function()
		local doc = fixture_doc()
		local result = text.page_to_text(doc, fixture_page(doc))
		if result == nil then error("expected a result") end
		-- "Hi" (x=100) and "World" (x=300) are both at y=700: same line,
		-- x-ascending order — the combined line text should read "Hi World".
		T.ok(result.text:find("Hi World", 1, true) ~= nil)
	end)
end)

T.describe("text: /Widths-based glyph advance", function()
	T.it("advances the text position between consecutive Tj calls using /Widths", function()
		-- Font 10: /Widths [500 600 700 800] for codes 65-68 (A-D).
		local content = "BT /F5 12 Tf 100 700 Td (AB) Tj (CD) Tj ET\n"
		local objs = {
			[1] = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
			[2] = "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
			[3] = "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
				.. "/Resources << /Font << /F5 5 0 R >> >> /Contents 4 0 R >>\nendobj\n",
			[4] = stream_obj(4, content),
			[5] = "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
				.. "/FirstChar 65 /LastChar 68 /Widths [500 600 700 800] >>\nendobj\n",
		}
		local doc = as_document(pdf.string_to_document(build_pdf(objs)))
		local page = pdf.resolve_reference(doc, { kind = "reference", num = 3, gen = 0 })
		local result, err = text.page_to_text(doc, page)
		T.eq(err, nil)
		if result == nil then error("expected a result") end

		local ab = as_table(find_span_with_text(result.spans, "AB"))
		local cd = as_table(find_span_with_text(result.spans, "CD"))
		T.eq(ab.x, 100)
		-- Advance = (width(A) + width(B)) / 1000 * Tfs = (500 + 600) / 1000 * 12 = 13.2.
		T.eq(cd.x, 113.2)
		T.eq(cd.y, ab.y)
	end)

	T.it("falls back to zero advance (old approximation) when the font has no /Widths", function()
		local content = "BT /F1 12 Tf 100 700 Td (AB) Tj (CD) Tj ET\n"
		local objs = {
			[1] = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
			[2] = "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
			[3] = "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
				.. "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n",
			[4] = stream_obj(4, content),
			[5] = "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
		}
		local doc = as_document(pdf.string_to_document(build_pdf(objs)))
		local page = pdf.resolve_reference(doc, { kind = "reference", num = 3, gen = 0 })
		local result = text.page_to_text(doc, page)
		if result == nil then error("expected a result") end

		local ab = as_table(find_span_with_text(result.spans, "AB"))
		local cd = as_table(find_span_with_text(result.spans, "CD"))
		T.eq(ab.x, 100)
		T.eq(cd.x, 100) -- no /Widths data: same documented w0-as-0 approximation as before
	end)
end)

T.describe("text: font-size-adaptive line grouping", function()
	T.it("groups a large-font-size gap that a fixed 3-unit tolerance would have split", function()
		local spans = {
			{ text = "top", x = 0, y = 700, font_name = nil, font_size = 20 },
			{ text = "bottom", x = 50, y = 696, font_name = nil, font_size = 20 }, -- gap 4 > old fixed 3
		}
		local lines = text.spans_to_reading_order(spans)
		T.eq(#lines, 1) -- tolerance = 20 * 0.3 = 6 >= 4: same line
	end)

	T.it("still separates a gap larger than the font-size-scaled tolerance", function()
		local spans = {
			{ text = "top", x = 0, y = 700, font_name = nil, font_size = 20 },
			{ text = "bottom", x = 0, y = 685, font_name = nil, font_size = 20 }, -- gap 15 > 20*0.3=6
		}
		local lines = text.spans_to_reading_order(spans)
		T.eq(#lines, 2)
	end)

	T.it("floors the tolerance at MIN_Y_LINE_TOLERANCE for small/zero font sizes", function()
		local spans = {
			{ text = "top", x = 0, y = 700, font_name = nil, font_size = 2 },
			-- gap 2.5: 2 * 0.3 = 0.6 would split, but the floor (3) keeps it together.
			{ text = "bottom", x = 0, y = 697.5, font_name = nil, font_size = 2 },
		}
		local lines = text.spans_to_reading_order(spans)
		T.eq(#lines, 1)
	end)
end)

T.describe("text: document_to_text", function()
	T.it("extracts every page in document order", function()
		local doc = fixture_doc()
		local results, err = text.document_to_text(doc)
		T.eq(err, nil)
		if results == nil then error("expected results") end
		T.eq(#results, 1)
		local page1 = results[1]
		if page1 == nil then error("expected page 1") end
		T.ok(page1.text:find("Hi World", 1, true) ~= nil)
	end)
end)

T.describe("text: spans_to_reading_order (independent of page extraction)", function()
	T.it("groups spans within Y tolerance into one line, sorted by x", function()
		local spans = {
			{ text = "b", x = 50, y = 100.4, font_name = nil, font_size = 12 },
			{ text = "a", x = 10, y = 100, font_name = nil, font_size = 12 },
			{ text = "c", x = 90, y = 99.8, font_name = nil, font_size = 12 },
		}
		local lines = text.spans_to_reading_order(spans)
		T.eq(#lines, 1)
		local line = as_table(lines[1])
		local line_spans = line.spans --[[: unknown]]
		T.eq(as_table(line_spans[1]).text, "a")
		T.eq(as_table(line_spans[2]).text, "b")
		T.eq(as_table(line_spans[3]).text, "c")
	end)

	T.it("separates spans beyond the Y tolerance into distinct lines, top to bottom", function()
		local spans = {
			{ text = "bottom", x = 0, y = 100, font_name = nil, font_size = 12 },
			{ text = "top", x = 0, y = 700, font_name = nil, font_size = 12 },
			{ text = "middle", x = 0, y = 400, font_name = nil, font_size = 12 },
		}
		local lines = text.spans_to_reading_order(spans)
		T.eq(#lines, 3)
		local l1 = as_table(lines[1])
		local l2 = as_table(lines[2])
		local l3 = as_table(lines[3])
		T.eq(as_table((l1.spans --[[: unknown]])[1]).text, "top")
		T.eq(as_table((l2.spans --[[: unknown]])[1]).text, "middle")
		T.eq(as_table((l3.spans --[[: unknown]])[1]).text, "bottom")
	end)

	T.it("reconstructs multi-column reading order (two columns, two rows)", function()
		local spans = {
			{ text = "col2row1", x = 300, y = 700, font_name = nil, font_size = 12 },
			{ text = "col1row1", x = 50, y = 700, font_name = nil, font_size = 12 },
			{ text = "col1row2", x = 50, y = 650, font_name = nil, font_size = 12 },
			{ text = "col2row2", x = 300, y = 650, font_name = nil, font_size = 12 },
		}
		local lines = text.spans_to_reading_order(spans)
		T.eq(#lines, 2)
		local l1 = as_table(lines[1])
		local l2 = as_table(lines[2])
		local row1 = as_table((l1.spans --[[: unknown]]))
		T.eq(as_table(row1[1]).text, "col1row1")
		T.eq(as_table(row1[2]).text, "col2row1")
		local row2 = as_table((l2.spans --[[: unknown]]))
		T.eq(as_table(row2[1]).text, "col1row2")
		T.eq(as_table(row2[2]).text, "col2row2")
	end)
end)
