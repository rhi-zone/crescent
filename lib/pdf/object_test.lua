-- lib/pdf/object_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local pdf_object = require("lib.pdf.object")

-- Parsed PDF objects are typed `unknown` for polymorphic slots (see
-- lib/pdf/object.lua header comment — same tradeoff lib/json makes for its
-- JSON value type). This narrows to a table so tests can index/take length.
--: (unknown) -> { [string]: unknown, [integer]: unknown }
local function as_table(v)
	if type(v) ~= "table" then error("expected table, got " .. type(v)) end
	return v
end

-- ── Booleans, numbers, null ───────────────────────────────────────────────────

T.describe("pdf.object: booleans and null", function()
	T.it("parses true", function()
		local v, err = pdf_object.string_to_object("true")
		T.eq(err, nil)
		T.eq(v, true)
	end)

	T.it("parses false", function()
		local v, err = pdf_object.string_to_object("false")
		T.eq(err, nil)
		T.eq(v, false)
	end)

	T.it("parses null to the null sentinel", function()
		local v, err = pdf_object.string_to_object("null")
		T.eq(err, nil)
		T.eq(v, pdf_object.null)
		T.eq(as_table(v).kind, "null")
	end)

	T.it("does not confuse 'truex' with the true keyword", function()
		local v, err = pdf_object.string_to_object("truex")
		T.ok(v == nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("pdf.object: numbers", function()
	T.it("parses a plain integer", function()
		local v = pdf_object.string_to_object("123")
		T.eq(v, 123)
	end)

	T.it("parses a negative integer", function()
		local v = pdf_object.string_to_object("-43")
		T.eq(v, -43)
	end)

	T.it("parses a leading-plus integer", function()
		local v = pdf_object.string_to_object("+17")
		T.eq(v, 17)
	end)

	T.it("parses a real number", function()
		local v = pdf_object.string_to_object("34.5")
		T.eq(v, 34.5)
	end)

	T.it("parses a real with no leading digit", function()
		local v = pdf_object.string_to_object("-.002")
		T.eq(v, -0.002)
	end)

	T.it("parses a real with no trailing digit", function()
		local v = pdf_object.string_to_object("4.")
		T.eq(v, 4.0)
	end)
end)

-- ── Strings ──────────────────────────────────────────────────────────────────

T.describe("pdf.object: literal strings", function()
	T.it("parses a simple literal string", function()
		local v = pdf_object.string_to_object("(hello world)")
		T.eq(v, "hello world")
	end)

	T.it("allows balanced unescaped parens to nest", function()
		local v = pdf_object.string_to_object("(a(b)c)")
		T.eq(v, "a(b)c")
	end)

	T.it("decodes standard escapes", function()
		local v = pdf_object.string_to_object("(a\\nb\\tc\\rd)")
		T.eq(v, "a\nb\tc\rd")
	end)

	T.it("decodes escaped parens and backslash", function()
		local v = pdf_object.string_to_object("(\\(\\)\\\\)")
		T.eq(v, "()\\")
	end)

	T.it("decodes octal escapes", function()
		local v = pdf_object.string_to_object("(\\101\\102)")
		T.eq(v, "AB")
	end)

	T.it("drops a backslash-newline line continuation", function()
		local v = pdf_object.string_to_object("(a\\\nb)")
		T.eq(v, "ab")
	end)

	T.it("normalizes a raw CRLF to a single LF", function()
		local v = pdf_object.string_to_object("(a\r\nb)")
		T.eq(v, "a\nb")
	end)

	T.it("normalizes a raw CR to a single LF", function()
		local v = pdf_object.string_to_object("(a\rb)")
		T.eq(v, "a\nb")
	end)

	T.it("keeps an unrecognized escaped char literally", function()
		local v = pdf_object.string_to_object("(\\q)")
		T.eq(v, "q")
	end)

	T.it("errors on an unterminated literal string", function()
		local v, err = pdf_object.string_to_object("(abc")
		T.ok(v == nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("pdf.object: hex strings", function()
	T.it("parses a hex string", function()
		local v = pdf_object.string_to_object("<48656C6C6F>")
		T.eq(v, "Hello")
	end)

	T.it("ignores whitespace inside a hex string", function()
		local v = pdf_object.string_to_object("<48 65 6C 6C 6F>")
		T.eq(v, "Hello")
	end)

	T.it("pads an odd trailing hex digit with 0", function()
		local v = pdf_object.string_to_object("<4>") -- '4' -> 0x40 = '@'
		T.eq(v, "@")
	end)

	T.it("errors on an invalid hex digit", function()
		local v, err = pdf_object.string_to_object("<4Z>")
		T.ok(v == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── Names ────────────────────────────────────────────────────────────────────

T.describe("pdf.object: names", function()
	T.it("parses a simple name", function()
		local v = as_table(pdf_object.string_to_object("/Type"))
		T.eq(v.kind, "name")
		T.eq(v.value, "Type")
	end)

	T.it("decodes #xx hex escapes in a name", function()
		local v = as_table(pdf_object.string_to_object("/A#42C")) -- #42 = 'B'
		T.eq(v.value, "ABC")
	end)

	T.it("stops a name at a delimiter", function()
		local r = pdf_object.new_reader("/Type/Other")
		local v = as_table(pdf_object.parse_object(r))
		T.eq(v.value, "Type")
		T.eq(r.pos, 6) -- positioned right at the second '/'
	end)

	T.it("parses the empty name", function()
		local r = pdf_object.new_reader("/ ")
		local v = as_table(pdf_object.parse_object(r))
		T.eq(v.kind, "name")
		T.eq(v.value, "")
	end)
end)

-- ── Arrays ───────────────────────────────────────────────────────────────────

T.describe("pdf.object: arrays", function()
	T.it("parses an empty array", function()
		local v = as_table(pdf_object.string_to_object("[]"))
		T.eq(#v, 0)
	end)

	T.it("parses a mixed-type array", function()
		local v = as_table(pdf_object.string_to_object("[1 2.5 (a) /N true false null]"))
		T.eq(#v, 7)
		T.eq(v[1], 1)
		T.eq(v[2], 2.5)
		T.eq(v[3], "a")
		T.eq(as_table(v[4]).kind, "name")
		T.eq(as_table(v[4]).value, "N")
		T.eq(v[5], true)
		T.eq(v[6], false)
		T.eq(v[7], pdf_object.null)
	end)

	T.it("parses a nested array", function()
		local v = as_table(pdf_object.string_to_object("[1 [2 3] 4]"))
		T.eq(#v, 3)
		local nested = as_table(v[2])
		T.eq(#nested, 2)
		T.eq(nested[1], 2)
		T.eq(nested[2], 3)
	end)

	T.it("errors on an unterminated array", function()
		local v, err = pdf_object.string_to_object("[1 2")
		T.ok(v == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── Dictionaries ─────────────────────────────────────────────────────────────

T.describe("pdf.object: dictionaries", function()
	T.it("parses an empty dictionary", function()
		local v = as_table(pdf_object.string_to_object("<< >>"))
		T.eq(next(v), nil)
	end)

	T.it("parses a simple dictionary", function()
		local v = as_table(pdf_object.string_to_object("<< /Type /Catalog /Count 3 >>"))
		local ty = as_table(v.Type)
		T.eq(ty.kind, "name")
		T.eq(ty.value, "Catalog")
		T.eq(v.Count, 3)
	end)

	T.it("parses a dictionary with a nested array value", function()
		local v = as_table(pdf_object.string_to_object("<< /Kids [1 0 R 2 0 R] >>"))
		local kids = as_table(v.Kids)
		T.eq(#kids, 2)
		local k1 = as_table(kids[1])
		T.eq(k1.kind, "reference")
		T.eq(k1.num, 1)
		T.eq(as_table(kids[2]).num, 2)
	end)

	T.it("parses a nested dictionary value", function()
		local v = as_table(pdf_object.string_to_object("<< /A << /B 1 >> >>"))
		T.eq(as_table(v.A).B, 1)
	end)

	T.it("errors on a non-name key", function()
		local v, err = pdf_object.string_to_object("<< 1 2 >>")
		T.ok(v == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── Indirect references vs plain numbers ────────────────────────────────────

T.describe("pdf.object: indirect references", function()
	T.it("parses 'N G R' as a reference", function()
		local v = as_table(pdf_object.string_to_object("12 0 R"))
		T.eq(v.kind, "reference")
		T.eq(v.num, 12)
		T.eq(v.gen, 0)
	end)

	T.it("parses a lone integer as a plain number, not a reference", function()
		local r = pdf_object.new_reader("12 0")
		local v = pdf_object.parse_object(r)
		T.eq(v, 12)
	end)

	T.it("does not treat a real number as a reference operand", function()
		-- "12.0 0 R" -- first operand has a decimal point, so this must parse
		-- as the plain number 12.0, leaving "0 R" unconsumed.
		local r = pdf_object.new_reader("12.0 0 R")
		local v = pdf_object.parse_object(r)
		T.eq(v, 12.0)
	end)

	T.it("does not treat a negative number as a reference operand", function()
		local r = pdf_object.new_reader("-1 0 R")
		local v = pdf_object.parse_object(r)
		T.eq(v, -1)
	end)
end)

-- ── Indirect objects: "N G obj ... endobj" ──────────────────────────────────

T.describe("pdf.object: indirect objects", function()
	T.it("parses a simple indirect object", function()
		local v, err = pdf_object.string_to_indirect_object("7 0 obj (hi) endobj")
		T.eq(err, nil)
		local iv = as_table(v)
		T.eq(iv.num, 7)
		T.eq(iv.gen, 0)
		T.eq(iv.value, "hi")
	end)

	T.it("parses an indirect object holding a dictionary", function()
		local v = as_table(pdf_object.string_to_indirect_object("1 0 obj << /Type /Catalog >> endobj"))
		local dict = as_table(v.value)
		T.eq(as_table(dict.Type).value, "Catalog")
	end)

	T.it("errors when 'endobj' is missing", function()
		local v, err = pdf_object.string_to_indirect_object("1 0 obj (x)")
		T.ok(v == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── Streams ──────────────────────────────────────────────────────────────────

T.describe("pdf.object: streams", function()
	T.it("parses a stream with a direct /Length", function()
		local src = "<< /Length 5 >>\nstream\nhello\nendstream"
		local v, err = pdf_object.string_to_object(src)
		T.eq(err, nil)
		local sv = as_table(v)
		T.eq(sv.kind, "stream")
		T.eq(sv.data, "hello")
	end)

	T.it("parses a stream whose 'stream' keyword is followed by a lone LF", function()
		local src = "<< /Length 3 >>\nstream\nabc\nendstream"
		local v = as_table(pdf_object.string_to_object(src))
		T.eq(v.data, "abc")
	end)

	T.it("parses a stream whose 'stream' keyword is followed by CRLF", function()
		local src = "<< /Length 3 >>\nstream\r\nabc\nendstream"
		local v = as_table(pdf_object.string_to_object(src))
		T.eq(v.data, "abc")
	end)

	T.it("rejects 'stream' followed by a lone CR", function()
		local src = "<< /Length 3 >>\nstream\rabc\nendstream"
		local v, err = pdf_object.string_to_object(src)
		T.ok(v == nil)
		T.ok(err ~= nil)
	end)

	T.it("falls back to scanning for endstream when /Length is an indirect reference and unresolved", function()
		local src = "<< /Length 9 0 R >>\nstream\nhello\nendstream"
		local v, err = pdf_object.string_to_object(src)
		T.eq(err, nil)
		local sv = as_table(v)
		T.eq(sv.kind, "stream")
		T.eq(sv.data, "hello")
	end)

	T.it("resolves an indirect /Length via opts.resolve_length", function()
		local src = "<< /Length 9 0 R >>\nstream\nhello\nendstream"
		local calls = 0
		--: (unknown) -> number | nil
		local function resolve_length(ref)
			calls = calls + 1
			T.eq(as_table(ref).num, 9)
			return 5
		end
		local v, err = pdf_object.string_to_object(src, nil, { resolve_length = resolve_length })
		T.eq(err, nil)
		T.eq(as_table(v).data, "hello")
		T.eq(calls, 1)
	end)

	T.it("errors when a direct /Length doesn't line up with 'endstream'", function()
		local src = "<< /Length 2 >>\nstream\nhello\nendstream"
		local v, err = pdf_object.string_to_object(src)
		T.ok(v == nil)
		T.ok(err ~= nil)
	end)

	T.it("parses a stream nested inside an indirect object", function()
		local src = "3 0 obj\n<< /Length 5 >>\nstream\nhello\nendstream\nendobj"
		local v, err = pdf_object.string_to_indirect_object(src)
		T.eq(err, nil)
		local sv = as_table(as_table(v).value)
		T.eq(sv.kind, "stream")
		T.eq(sv.data, "hello")
	end)
end)

-- ── Comments and whitespace ──────────────────────────────────────────────────

T.describe("pdf.object: comments", function()
	T.it("skips a comment before an object", function()
		local v = pdf_object.string_to_object("% a comment\n42")
		T.eq(v, 42)
	end)

	T.it("skips comments inside an array", function()
		local v = as_table(pdf_object.string_to_object("[1 % comment\n 2]"))
		T.eq(#v, 2)
		T.eq(v[2], 2)
	end)
end)
