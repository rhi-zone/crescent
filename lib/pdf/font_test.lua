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
--:: Font = { code_width: integer, code_to_unicode: (integer) -> (string | nil) }

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

	T.it("errors clearly on a non-Identity /Encoding (documented CID gap)", function()
		local dict = { Subtype = name("Type0"), Encoding = name("UniGB-UCS2-H") }
		local f, err = font.font_from_dict(NO_DOC, dict)
		T.ok(f == nil)
		T.ok(err ~= nil)
	end)
end)
