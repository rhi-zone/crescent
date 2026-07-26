-- lib/pdf/font_test.lua
-- Tests for lib/pdf/font.lua's character-code -> Unicode mapping.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local font = require("lib.pdf.font")

-- Mirrors lib/pdf/font.lua's Font shape (same-shape local redeclaration —
-- type declarations don't cross `require` boundaries in this typechecker,
-- same pattern lib/pdf/xref.lua uses for ParseOpts/XrefOpts).
--:: Font = { code_width: integer, code_to_unicode: (integer) -> (string | nil), code_to_width: ((integer) -> number) | nil }

--: (unknown) -> Font
local function as_font(v)
	if type(v) ~= "table" then error("expected a Font table, got " .. type(v)) end
	local t = v --[[: Font]]
	return t
end

-- font_from_dict's `doc` parameter is only used to resolve indirect
-- references; none of these tests use indirect references inside a font
-- dictionary, so an empty placeholder document is sufficient.
local NO_DOC = { bytes = "", entries = {}, trailer = {} }

--: (string) -> unknown
local function name(n) return { kind = "name", value = n } end

--: (string) -> unknown
-- Builds an uncompressed (no /Filter) PDF stream object, decodable by
-- pdf.stream_to_bytes without needing real deflate/xref machinery.
local function raw_stream(text)
	return { kind = "stream", dict = {}, data = text }
end

T.describe("font: simple fonts, no /Encoding (StandardEncoding default)", function()
	T.it("maps ASCII letters via StandardEncoding + AGL", function()
		local f, err = font.font_from_dict(NO_DOC, { Type = name("Font"), Subtype = name("Type1") })
		T.eq(err, nil)
		local ft = as_font(f)
		T.eq(ft.code_width, 1)
		local c2u = ft.code_to_unicode
		T.eq(c2u(65), "A")
		T.eq(c2u(97), "a")
		T.eq(c2u(32), " ")
	end)

	T.it("maps the StandardEncoding 'fi' ligature to its Unicode ligature codepoint", function()
		local f = as_font(font.font_from_dict(NO_DOC, {}))
		local c2u = f.code_to_unicode
		-- code 174 = "fi" in StandardEncoding; U+FB01 = EF AC 81 in UTF-8.
		T.eq(c2u(174), "\239\172\129")
	end)

	T.it("returns nil for an unassigned code", function()
		local f = as_font(font.font_from_dict(NO_DOC, {}))
		local c2u = f.code_to_unicode
		T.eq(c2u(1), nil)
	end)
end)

T.describe("font: /Encoding as a direct base-encoding name", function()
	T.it("WinAnsiEncoding maps code 128 to the Euro sign", function()
		local f = as_font(font.font_from_dict(NO_DOC, { Encoding = name("WinAnsiEncoding") }))
		local c2u = f.code_to_unicode
		T.eq(c2u(128), "\226\130\172") -- U+20AC in UTF-8
	end)

	T.it("errors clearly on an unsupported /Encoding name", function()
		local f, err = font.font_from_dict(NO_DOC, { Encoding = name("MacExpertEncoding") })
		T.ok(f == nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("font: /Encoding as a dict with /BaseEncoding + /Differences", function()
	T.it("remaps individual codes via /Differences", function()
		local encoding = {
			BaseEncoding = name("WinAnsiEncoding"),
			Differences = { 65, name("Euro"), name("space") },
		}
		local f = as_font(font.font_from_dict(NO_DOC, { Encoding = encoding }))
		local c2u = f.code_to_unicode
		T.eq(c2u(65), "\226\130\172") -- code 65 remapped to Euro
		T.eq(c2u(66), " ") -- code 66 remapped to space (sequential run continues)
		T.eq(c2u(67), "C") -- untouched, falls back to WinAnsiEncoding base
	end)

	T.it("defaults to StandardEncoding when /BaseEncoding is absent", function()
		local encoding = { Differences = { 65, name("space") } }
		local f = as_font(font.font_from_dict(NO_DOC, { Encoding = encoding }))
		local c2u = f.code_to_unicode
		T.eq(c2u(65), " ")
		T.eq(c2u(97), "a") -- base StandardEncoding still applies elsewhere
	end)
end)

T.describe("font: full Adobe Glyph List coverage", function()
	T.it("maps a glyph name well outside the old core-encoding-tables subset", function()
		-- "onethird" (U+2153) never appears in StandardEncoding, WinAnsiEncoding,
		-- or MacRomanEncoding — only reachable via /Differences into the full AGL.
		local encoding = { Differences = { 65, name("onethird") } }
		local f = as_font(font.font_from_dict(NO_DOC, { Encoding = encoding }))
		local c2u = f.code_to_unicode
		T.eq(c2u(65), "\226\133\147") -- U+2153 in UTF-8
	end)

	T.it("maps a multi-codepoint AGL entry (Hebrew letter + point)", function()
		local encoding = { Differences = { 65, name("dalethatafpatah") } }
		local f = as_font(font.font_from_dict(NO_DOC, { Encoding = encoding }))
		local c2u = f.code_to_unicode
		-- dalet (U+05D3) + hataf patah (U+05B2), each in UTF-8.
		T.eq(c2u(65), "\215\147\214\178")
	end)

	T.it("returns nil for a glyph name not in the AGL at all", function()
		local encoding = { Differences = { 65, name("not_a_real_glyph_name") } }
		local f = as_font(font.font_from_dict(NO_DOC, { Encoding = encoding }))
		local c2u = f.code_to_unicode
		T.eq(c2u(65), nil)
	end)
end)

T.describe("font: /ToUnicode CMap takes priority over /Encoding", function()
	T.it("bfchar entries override the base encoding mapping", function()
		local cmap = [[
/CIDInit /ProcSet findresource begin
1 begincodespacerange
<00> <ff>
endcodespacerange
1 beginbfchar
<41> <005A>
endbfchar
endcmap
]]
		local f = as_font(font.font_from_dict(NO_DOC, { ToUnicode = raw_stream(cmap) }))
		local c2u = f.code_to_unicode
		T.eq(c2u(0x41), "Z") -- overridden by CMap instead of StandardEncoding's "A"
		T.eq(c2u(66), "B") -- falls back to StandardEncoding when CMap has no entry
	end)

	T.it("bfrange with an explicit destination array maps each code individually", function()
		local cmap = [[
1 beginbfrange
<01> <03> [<0041> <0042> <0043>]
endbfrange
]]
		local f = as_font(font.font_from_dict(NO_DOC, { ToUnicode = raw_stream(cmap) }))
		local c2u = f.code_to_unicode
		T.eq(c2u(1), "A")
		T.eq(c2u(2), "B")
		T.eq(c2u(3), "C")
	end)

	T.it("bfrange with a single template destination increments across the range", function()
		local cmap = [[
1 beginbfrange
<10> <13> <0041>
endbfrange
]]
		local f = as_font(font.font_from_dict(NO_DOC, { ToUnicode = raw_stream(cmap) }))
		local c2u = f.code_to_unicode
		T.eq(c2u(0x10), "A")
		T.eq(c2u(0x11), "B")
		T.eq(c2u(0x12), "C")
		T.eq(c2u(0x13), "D")
	end)
end)

T.describe("font: Type0 composite fonts (Identity-H scope)", function()
	T.it("maps 2-byte codes via /ToUnicode when /Encoding is Identity-H", function()
		local cmap = [[
1 beginbfchar
<0041> <0048>
<0042> <0069>
endbfchar
]]
		local dict = {
			Subtype = name("Type0"),
			Encoding = name("Identity-H"),
			ToUnicode = raw_stream(cmap),
		}
		local f, err = font.font_from_dict(NO_DOC, dict)
		T.eq(err, nil)
		local ft = as_font(f)
		T.eq(ft.code_width, 2)
		local c2u = ft.code_to_unicode
		T.eq(c2u(0x0041), "H")
		T.eq(c2u(0x0042), "i")
	end)

	T.it("errors clearly when a Type0 font has no /ToUnicode CMap", function()
		local dict = { Subtype = name("Type0"), Encoding = name("Identity-H") }
		local f, err = font.font_from_dict(NO_DOC, dict)
		T.ok(f == nil)
		T.ok(err ~= nil)
	end)

	T.it("errors clearly on a non-Identity, non-UTF16, non-embedded /Encoding (documented CID gap)", function()
		-- UniGB-UCS2-H is a real predefined CMap name but NOT one of the
		-- four UTF16 variants this module special-cases (see
		-- PREDEFINED_UTF16_CMAPS) — still a documented gap.
		local dict = { Subtype = name("Type0"), Encoding = name("UniGB-UCS2-H") }
		local f, err = font.font_from_dict(NO_DOC, dict)
		T.ok(f == nil)
		T.ok(err ~= nil)
	end)

	T.it("/ToUnicode takes priority even when /Encoding is a non-Identity name", function()
		-- Priority order (file header): /ToUnicode always wins when present,
		-- regardless of /Encoding — this used to error unconditionally on a
		-- non-Identity /Encoding even with /ToUnicode present; no longer.
		local cmap = "1 beginbfchar\n<0041> <0048>\nendbfchar\n"
		local dict = {
			Subtype = name("Type0"),
			Encoding = name("UniGB-UCS2-H"),
			ToUnicode = raw_stream(cmap),
		}
		local f, err = font.font_from_dict(NO_DOC, dict)
		T.eq(err, nil)
		local ft = as_font(f)
		T.eq(ft.code_to_unicode(0x0041), "H")
	end)
end)

T.describe("font: Type0 predefined Uni*-UTF16-* CMaps", function()
	T.it("decodes codes directly as UTF-16BE when /Encoding is UniGB-UTF16-H and there's no /ToUnicode", function()
		local dict = { Subtype = name("Type0"), Encoding = name("UniGB-UTF16-H") }
		local f, err = font.font_from_dict(NO_DOC, dict)
		T.eq(err, nil)
		local ft = as_font(f)
		T.eq(ft.code_width, 2)
		-- U+4E2D (中) as a UTF-16BE code unit.
		T.eq(ft.code_to_unicode(0x4E2D), "\228\184\173")
	end)

	T.it("supports the -V (vertical) variant identically to -H", function()
		local dict = { Subtype = name("Type0"), Encoding = name("UniJIS-UTF16-V") }
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		T.eq(f.code_to_unicode(0x3042), "\227\129\130") -- U+3042 あ
	end)

	T.it("/ToUnicode still overrides a predefined UTF16 CMap when present", function()
		local cmap = "1 beginbfchar\n<0041> <005A>\nendbfchar\n"
		local dict = {
			Subtype = name("Type0"),
			Encoding = name("UniGB-UTF16-H"),
			ToUnicode = raw_stream(cmap),
		}
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		T.eq(f.code_to_unicode(0x0041), "Z") -- from ToUnicode, not direct UTF-16BE ("A")
	end)
end)

T.describe("font: Type0 embedded /Encoding CMap stream (bfchar/bfrange syntax)", function()
	T.it("parses begincodespacerange + beginbfchar from an embedded /Encoding CMap", function()
		local cmap = [[
1 begincodespacerange
<0000> <FFFF>
endcodespacerange
1 beginbfchar
<0001> <0041>
endbfchar
]]
		local dict = { Subtype = name("Type0"), Encoding = raw_stream(cmap) }
		local f, err = font.font_from_dict(NO_DOC, dict)
		T.eq(err, nil)
		local ft = as_font(f)
		T.eq(ft.code_width, 2) -- derived from the 2-byte codespacerange
		T.eq(ft.code_to_unicode(1), "A")
	end)

	T.it("derives a 1-byte code_width from a 1-byte codespacerange", function()
		local cmap = [[
1 begincodespacerange
<00> <FF>
endcodespacerange
1 beginbfchar
<41> <0058>
endbfchar
]]
		local dict = { Subtype = name("Type0"), Encoding = raw_stream(cmap) }
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		T.eq(f.code_width, 1)
		T.eq(f.code_to_unicode(0x41), "X")
	end)
end)

T.describe("font: /Widths parsing", function()
	T.it("returns each in-range code's /Widths entry", function()
		local dict = { FirstChar = 65, LastChar = 67, Widths = { 500, 600, 700 } }
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		local c2w = f.code_to_width
		if c2w == nil then error("expected code_to_width to be present") end
		T.eq(c2w(65), 500)
		T.eq(c2w(66), 600)
		T.eq(c2w(67), 700)
	end)

	T.it("falls back to /FontDescriptor /MissingWidth for an out-of-range code", function()
		local dict = {
			FirstChar = 65,
			LastChar = 65,
			Widths = { 500 },
			FontDescriptor = { MissingWidth = 250 },
		}
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		local c2w = f.code_to_width
		if c2w == nil then error("expected code_to_width to be present") end
		T.eq(c2w(65), 500)
		T.eq(c2w(90), 250) -- out of [FirstChar, LastChar]: /MissingWidth
	end)

	T.it("defaults /MissingWidth to 0 when /FontDescriptor is absent", function()
		local dict = { FirstChar = 65, LastChar = 65, Widths = { 500 } }
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		local c2w = f.code_to_width
		if c2w == nil then error("expected code_to_width to be present") end
		T.eq(c2w(90), 0)
	end)

	T.it("code_to_width is nil when the font has no /Widths array at all", function()
		local f = as_font(font.font_from_dict(NO_DOC, {}))
		T.eq(f.code_to_width, nil)
	end)

	T.it("code_to_width is nil for an Identity-H Type0 font with no /DescendantFonts", function()
		local dict = {
			Subtype = name("Type0"),
			Encoding = name("Identity-H"),
			ToUnicode = raw_stream("1 beginbfchar\n<0041> <0041>\nendbfchar\n"),
		}
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		T.eq(f.code_to_width, nil)
	end)
end)

T.describe("font: CID /DW + /W width parsing (Identity-H/V Type0 fonts)", function()
	--: (unknown) -> unknown
	local function cidfont_type0(descendant)
		return {
			Subtype = name("Type0"),
			Encoding = name("Identity-H"),
			ToUnicode = raw_stream("1 beginbfchar\n<0041> <0041>\nendbfchar\n"),
			DescendantFonts = { descendant },
		}
	end

	T.it("looks up a CID's width from the 'cid [w1 w2 ...]' /W form", function()
		local dict = cidfont_type0({ Subtype = name("CIDFontType2"), DW = 1000, W = { 3, { 500, 600, 700 } } })
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		local c2w = f.code_to_width
		if c2w == nil then error("expected code_to_width to be present") end
		T.eq(c2w(3), 500)
		T.eq(c2w(4), 600)
		T.eq(c2w(5), 700)
	end)

	T.it("looks up a CID's width from the 'cidFirst cidLast w' /W form", function()
		local dict = cidfont_type0({ Subtype = name("CIDFontType2"), W = { 10, 20, 850 } })
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		local c2w = f.code_to_width
		if c2w == nil then error("expected code_to_width to be present") end
		T.eq(c2w(10), 850)
		T.eq(c2w(15), 850)
		T.eq(c2w(20), 850)
	end)

	T.it("mixes both /W forms in one array", function()
		local dict = cidfont_type0({ Subtype = name("CIDFontType2"), W = { 3, { 500, 600 }, 10, 20, 850 } })
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		local c2w = f.code_to_width
		if c2w == nil then error("expected code_to_width to be present") end
		T.eq(c2w(3), 500)
		T.eq(c2w(4), 600)
		T.eq(c2w(15), 850)
	end)

	T.it("falls back to /DW for a CID not covered by /W", function()
		local dict = cidfont_type0({ Subtype = name("CIDFontType2"), DW = 750, W = { 3, { 500 } } })
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		local c2w = f.code_to_width
		if c2w == nil then error("expected code_to_width to be present") end
		T.eq(c2w(999), 750)
	end)

	T.it("defaults /DW to 1000 (spec default) when absent", function()
		local dict = cidfont_type0({ Subtype = name("CIDFontType2") })
		local f = as_font(font.font_from_dict(NO_DOC, dict))
		local c2w = f.code_to_width
		if c2w == nil then error("expected code_to_width to be present") end
		T.eq(c2w(999), 1000)
	end)
end)
