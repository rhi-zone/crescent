if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local csv = require("lib.csv")

-- ===========================================================================
-- csv.decode — basic
-- ===========================================================================

T.describe("csv.decode basic", function()
  T.it("parses a simple row", function()
    local rows = csv.decode("a,b,c\n")
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a")
    T.eq(rows[1][2], "b")
    T.eq(rows[1][3], "c")
  end)

  T.it("parses multiple rows", function()
    local rows = csv.decode("a,b\nc,d\n")
    T.eq(#rows, 2)
    T.eq(rows[1][1], "a")
    T.eq(rows[1][2], "b")
    T.eq(rows[2][1], "c")
    T.eq(rows[2][2], "d")
  end)

  T.it("parses without trailing newline", function()
    local rows = csv.decode("a,b\nc,d")
    T.eq(#rows, 2)
    T.eq(rows[2][1], "c")
    T.eq(rows[2][2], "d")
  end)

  T.it("handles empty input", function()
    local rows = csv.decode("")
    T.eq(#rows, 0)
  end)

  T.it("handles single field", function()
    local rows = csv.decode("hello")
    T.eq(#rows, 1)
    T.eq(rows[1][1], "hello")
  end)

  T.it("handles single row with trailing newline", function()
    local rows = csv.decode("x,y,z\n")
    T.eq(#rows, 1)
    T.eq(#rows[1], 3)
  end)

  T.it("returns error for non-string input", function()
    local result, err = csv.decode(42)
    T.eq(result, nil)
    T.ok(err:find("expected string"))
  end)

  T.it("handles numeric-looking strings as strings by default", function()
    local rows = csv.decode("1,2.5,3\n")
    T.eq(rows[1][1], "1")
    T.eq(rows[1][2], "2.5")
    T.eq(rows[1][3], "3")
  end)
end)

-- ===========================================================================
-- csv.decode — quoting
-- ===========================================================================

T.describe("csv.decode quoting", function()
  T.it("handles quoted fields with commas", function()
    local rows = csv.decode('"a,b",c\n')
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a,b")
    T.eq(rows[1][2], "c")
  end)

  T.it("handles quoted fields with newlines", function()
    local rows = csv.decode('"line1\nline2",b\n')
    T.eq(#rows, 1)
    T.eq(rows[1][1], "line1\nline2")
    T.eq(rows[1][2], "b")
  end)

  T.it("handles escaped quotes (doubled)", function()
    local rows = csv.decode('"a""b",c\n')
    T.eq(#rows, 1)
    T.eq(rows[1][1], 'a"b')
    T.eq(rows[1][2], "c")
  end)

  T.it("handles multiple escaped quotes", function()
    local rows = csv.decode('"a""b""c"\n')
    T.eq(#rows, 1)
    T.eq(rows[1][1], 'a"b"c')
  end)

  T.it("handles empty quoted field", function()
    local rows = csv.decode('"",b\n')
    T.eq(#rows, 1)
    T.eq(rows[1][1], "")
    T.eq(rows[1][2], "b")
  end)

  T.it("returns error for unterminated quote", function()
    local result, err = csv.decode('"unterminated')
    T.eq(result, nil)
    T.ok(err:find("unterminated"))
  end)

  T.it("handles quoted field with CRLF inside", function()
    local rows = csv.decode('"a\r\nb",c\n')
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a\r\nb")
    T.eq(rows[1][2], "c")
  end)

  T.it("quoted field at end of string (no newline)", function()
    local rows = csv.decode('"hello"')
    T.eq(#rows, 1)
    T.eq(rows[1][1], "hello")
  end)

  T.it("quoted field only with quote char inside", function()
    local rows = csv.decode('""""\n')  -- field contains one "
    T.eq(#rows, 1)
    T.eq(rows[1][1], '"')
  end)
end)

-- ===========================================================================
-- csv.decode — empty fields
-- ===========================================================================

T.describe("csv.decode empty fields", function()
  T.it("handles leading empty field", function()
    local rows = csv.decode(",b,c\n")
    T.eq(#rows, 1)
    T.eq(rows[1][1], "")
    T.eq(rows[1][2], "b")
    T.eq(rows[1][3], "c")
  end)

  T.it("handles trailing empty field", function()
    local rows = csv.decode("a,b,\n")
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a")
    T.eq(rows[1][2], "b")
    T.eq(rows[1][3], "")
  end)

  T.it("handles all empty fields", function()
    local rows = csv.decode(",,,\n")
    T.eq(#rows, 1)
    T.eq(#rows[1], 4)
    T.eq(rows[1][1], "")
    T.eq(rows[1][4], "")
  end)

  T.it("handles middle empty field", function()
    local rows = csv.decode("a,,c\n")
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a")
    T.eq(rows[1][2], "")
    T.eq(rows[1][3], "c")
  end)

  T.it("single comma gives two empty fields", function()
    local rows = csv.decode(",\n")
    T.eq(#rows, 1)
    T.eq(#rows[1], 2)
    T.eq(rows[1][1], "")
    T.eq(rows[1][2], "")
  end)
end)

-- ===========================================================================
-- csv.decode — line endings
-- ===========================================================================

T.describe("csv.decode line endings", function()
  T.it("handles CRLF line endings", function()
    local rows = csv.decode("a,b\r\nc,d\r\n")
    T.eq(#rows, 2)
    T.eq(rows[1][1], "a")
    T.eq(rows[2][1], "c")
  end)

  T.it("handles LF line endings", function()
    local rows = csv.decode("a,b\nc,d\n")
    T.eq(#rows, 2)
    T.eq(rows[1][2], "b")
    T.eq(rows[2][2], "d")
  end)

  T.it("handles CR-only line endings", function()
    local rows = csv.decode("a,b\rc,d\r")
    T.eq(#rows, 2)
    T.eq(rows[1][1], "a")
    T.eq(rows[2][1], "c")
  end)

  T.it("handles mixed line endings", function()
    local rows = csv.decode("a,b\r\nc,d\n")
    T.eq(#rows, 2)
    T.eq(rows[1][1], "a")
    T.eq(rows[2][1], "c")
  end)

  T.it("handles CRLF without trailing newline", function()
    local rows = csv.decode("a,b\r\nc,d")
    T.eq(#rows, 2)
    T.eq(rows[2][2], "d")
  end)
end)

-- ===========================================================================
-- csv.decode — headers option
-- ===========================================================================

T.describe("csv.decode headers option", function()
  T.it("returns keyed tables with headers=true", function()
    local records = csv.decode("name,age\nAlice,30\nBob,25\n", { headers = true })
    T.eq(#records, 2)
    T.eq(records[1].name, "Alice")
    T.eq(records[1].age, "30")
    T.eq(records[2].name, "Bob")
    T.eq(records[2].age, "25")
  end)

  T.it("handles headers mode with empty data", function()
    local records = csv.decode("name,age\n", { headers = true })
    T.eq(#records, 0)
  end)

  T.it("handles missing fields in headers mode", function()
    local records = csv.decode("a,b,c\n1,2\n", { headers = true })
    T.eq(#records, 1)
    T.eq(records[1].a, "1")
    T.eq(records[1].b, "2")
    T.eq(records[1].c, nil)  -- missing field is nil (not mapped)
  end)

  T.it("headers with multiple rows", function()
    local records = csv.decode("x,y\n1,2\n3,4\n5,6\n", { headers = true })
    T.eq(#records, 3)
    T.eq(records[3].x, "5")
    T.eq(records[3].y, "6")
  end)
end)

-- ===========================================================================
-- csv.decode — coerce option
-- ===========================================================================

T.describe("csv.decode coerce option", function()
  T.it("converts integers", function()
    local rows = csv.decode("1,2,3\n", { coerce = true })
    T.eq(rows[1][1], 1)
    T.eq(rows[1][2], 2)
    T.eq(rows[1][3], 3)
  end)

  T.it("converts floats", function()
    local rows = csv.decode("3.14,2.5\n", { coerce = true })
    T.eq(rows[1][1], 3.14)
    T.eq(rows[1][2], 2.5)
  end)

  T.it("converts true/false", function()
    local rows = csv.decode("true,false,maybe\n", { coerce = true })
    T.eq(rows[1][1], true)
    T.eq(rows[1][2], false)
    T.eq(rows[1][3], "maybe")
  end)

  T.it("keeps non-convertible strings as strings", function()
    local rows = csv.decode("hello,world\n", { coerce = true })
    T.eq(rows[1][1], "hello")
    T.eq(rows[1][2], "world")
  end)

  T.it("coerce combined with headers", function()
    local records = csv.decode("name,score\nAlice,42\n", { headers = true, coerce = true })
    T.eq(records[1].name, "Alice")
    T.eq(records[1].score, 42)
  end)
end)

-- ===========================================================================
-- csv.decode — trim option
-- ===========================================================================

T.describe("csv.decode trim option", function()
  T.it("trims leading and trailing spaces from unquoted fields", function()
    local rows = csv.decode("  a  ,  b  ,  c  \n", { trim = true })
    T.eq(rows[1][1], "a")
    T.eq(rows[1][2], "b")
    T.eq(rows[1][3], "c")
  end)

  T.it("does not trim quoted fields", function()
    local rows = csv.decode('"  a  ",b\n', { trim = true })
    T.eq(rows[1][1], "  a  ")
    T.eq(rows[1][2], "b")
  end)

  T.it("trim with empty fields stays empty", function()
    local rows = csv.decode("   ,   \n", { trim = true })
    T.eq(rows[1][1], "")
    T.eq(rows[1][2], "")
  end)
end)

-- ===========================================================================
-- csv.decode — custom separator
-- ===========================================================================

T.describe("csv.decode custom separator", function()
  T.it("handles tab separator", function()
    local rows = csv.decode("a\tb\tc\n", { separator = "\t" })
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a")
    T.eq(rows[1][2], "b")
    T.eq(rows[1][3], "c")
  end)

  T.it("handles semicolon separator", function()
    local rows = csv.decode("a;b;c\n", { separator = ";" })
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a")
    T.eq(rows[1][2], "b")
    T.eq(rows[1][3], "c")
  end)

  T.it("handles pipe separator with quoting", function()
    local rows = csv.decode('"a|b"|c\n', { separator = "|" })
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a|b")
    T.eq(rows[1][2], "c")
  end)
end)

-- ===========================================================================
-- csv.decode_row
-- ===========================================================================

T.describe("csv.decode_row", function()
  T.it("decodes a single unquoted row", function()
    local row = csv.decode_row("a,b,c")
    T.eq(#row, 3)
    T.eq(row[1], "a")
    T.eq(row[2], "b")
    T.eq(row[3], "c")
  end)

  T.it("decodes quoted field with comma", function()
    local row = csv.decode_row('"a,b",c')
    T.eq(row[1], "a,b")
    T.eq(row[2], "c")
  end)

  T.it("decodes empty input as empty row", function()
    local row = csv.decode_row("")
    T.eq(#row, 0)
  end)

  T.it("returns nil, err on unterminated quote", function()
    local row, err = csv.decode_row('"bad')
    T.eq(row, nil)
    T.ok(err ~= nil)
  end)

  T.it("respects separator option", function()
    local row = csv.decode_row("a;b;c", { separator = ";" })
    T.eq(row[1], "a")
    T.eq(row[2], "b")
    T.eq(row[3], "c")
  end)
end)

-- ===========================================================================
-- csv.encode_row
-- ===========================================================================

T.describe("csv.encode_row", function()
  T.it("encodes a plain row", function()
    local s = csv.encode_row({"a", "b", "c"})
    T.eq(s, "a,b,c")
  end)

  T.it("quotes field containing comma", function()
    local s = csv.encode_row({"a,b", "c"})
    T.eq(s, '"a,b",c')
  end)

  T.it("quotes field containing quote char and doubles it", function()
    local s = csv.encode_row({'a"b', "c"})
    T.eq(s, '"a""b",c')
  end)

  T.it("quotes field containing newline", function()
    local s = csv.encode_row({"a\nb", "c"})
    T.eq(s, '"a\nb",c')
  end)

  T.it("quotes field containing CR", function()
    local s = csv.encode_row({"a\rb", "c"})
    T.eq(s, '"a\rb",c')
  end)

  T.it("does not quote plain empty field", function()
    local s = csv.encode_row({"", "b"})
    T.eq(s, ",b")
  end)

  T.it("quotes field with leading space", function()
    local s = csv.encode_row({" a", "b"})
    T.eq(s, '" a",b')
  end)

  T.it("quotes field with trailing space", function()
    local s = csv.encode_row({"a ", "b"})
    T.eq(s, '"a ",b')
  end)

  T.it("always_quote option quotes all fields", function()
    local s = csv.encode_row({"a", "b"}, { always_quote = true })
    T.eq(s, '"a","b"')
  end)

  T.it("uses custom separator", function()
    local s = csv.encode_row({"a", "b"}, { separator = "\t" })
    T.eq(s, "a\tb")
  end)

  T.it("encodes numbers via tostring", function()
    local s = csv.encode_row({1, 2.5, true})
    T.eq(s, "1,2.5,true")
  end)
end)

-- ===========================================================================
-- csv.encode
-- ===========================================================================

T.describe("csv.encode", function()
  T.it("encodes simple rows", function()
    local s = csv.encode({ { "a", "b", "c" } })
    T.eq(s, "a,b,c\n")
  end)

  T.it("encodes multiple rows", function()
    local s = csv.encode({ { "a", "b" }, { "c", "d" } })
    T.eq(s, "a,b\nc,d\n")
  end)

  T.it("quotes fields with commas", function()
    local s = csv.encode({ { "a,b", "c" } })
    T.eq(s, '"a,b",c\n')
  end)

  T.it("quotes fields with quotes and doubles them", function()
    local s = csv.encode({ { 'a"b', "c" } })
    T.eq(s, '"a""b",c\n')
  end)

  T.it("quotes fields with newlines", function()
    local s = csv.encode({ { "a\nb", "c" } })
    T.eq(s, '"a\nb",c\n')
  end)

  T.it("encodes empty fields", function()
    local s = csv.encode({ { "", "b", "" } })
    T.eq(s, ",b,\n")
  end)

  T.it("uses custom separator option", function()
    local s = csv.encode({ { "a", "b" } }, { separator = "\t" })
    T.eq(s, "a\tb\n")
  end)

  T.it("uses custom line_ending option", function()
    local s = csv.encode({ { "a", "b" } }, { line_ending = "\r\n" })
    T.eq(s, "a,b\r\n")
  end)

  T.it("always_quote option", function()
    local s = csv.encode({ { "a", "b" } }, { always_quote = true })
    T.eq(s, '"a","b"\n')
  end)

  T.it("returns empty string for empty rows table", function()
    local s = csv.encode({})
    T.eq(s, "")
  end)

  T.it("CRLF line_ending produces RFC 4180 output", function()
    local s = csv.encode({ { "a", "b" }, { "c", "d" } }, { line_ending = "\r\n" })
    T.eq(s, "a,b\r\nc,d\r\n")
  end)
end)

-- ===========================================================================
-- csv.encode_records
-- ===========================================================================

T.describe("csv.encode_records", function()
  T.it("produces header row + data rows", function()
    local records = {
      { name = "Alice", age = "30" },
      { name = "Bob",   age = "25" },
    }
    local s = csv.encode_records(records, { "name", "age" })
    T.eq(s, "name,age\nAlice,30\nBob,25\n")
  end)

  T.it("respects key order from keys array", function()
    local records = { { a = "1", b = "2", c = "3" } }
    local s = csv.encode_records(records, { "c", "a", "b" })
    T.eq(s, "c,a,b\n3,1,2\n")
  end)

  T.it("uses empty string for missing keys", function()
    local records = { { name = "Alice" } }
    local s = csv.encode_records(records, { "name", "age" })
    T.eq(s, "name,age\nAlice,\n")
  end)

  T.it("encodes zero records (header only)", function()
    local s = csv.encode_records({}, { "name", "age" })
    T.eq(s, "name,age\n")
  end)

  T.it("quotes fields that need it", function()
    local records = { { name = "Smith, John", note = 'says "hi"' } }
    local s = csv.encode_records(records, { "name", "note" })
    T.eq(s, 'name,note\n"Smith, John","says ""hi"""\n')
  end)

  T.it("uses custom separator and line_ending", function()
    local records = { { a = "1", b = "2" } }
    local s = csv.encode_records(records, { "a", "b" }, { separator = ";", line_ending = "\r\n" })
    T.eq(s, "a;b\r\n1;2\r\n")
  end)
end)

-- ===========================================================================
-- Roundtrip
-- ===========================================================================

T.describe("csv roundtrip", function()
  T.it("decode(encode(rows)) equals original rows", function()
    local original = { { "a", "b", "c" }, { "d", "e", "f" } }
    local encoded = csv.encode(original)
    local decoded = csv.decode(encoded)
    T.eq(#decoded, 2)
    T.eq(decoded[1][1], "a")
    T.eq(decoded[1][3], "c")
    T.eq(decoded[2][1], "d")
    T.eq(decoded[2][3], "f")
  end)

  T.it("roundtrips fields with special characters", function()
    local original = { { 'he said "hi"', "a,b", "line1\nline2" } }
    local encoded = csv.encode(original)
    local decoded = csv.decode(encoded)
    T.eq(#decoded, 1)
    T.eq(decoded[1][1], 'he said "hi"')
    T.eq(decoded[1][2], "a,b")
    T.eq(decoded[1][3], "line1\nline2")
  end)

  T.it("roundtrips empty fields", function()
    local original = { { "", "", "" } }
    local encoded = csv.encode(original)
    local decoded = csv.decode(encoded)
    T.eq(#decoded, 1)
    T.eq(decoded[1][1], "")
    T.eq(decoded[1][2], "")
    T.eq(decoded[1][3], "")
  end)

  T.it("roundtrips with custom separator", function()
    local original = { { "a", "b" }, { "c", "d" } }
    local opts = { separator = ";" }
    local encoded = csv.encode(original, opts)
    local decoded = csv.decode(encoded, opts)
    T.eq(#decoded, 2)
    T.eq(decoded[1][1], "a")
    T.eq(decoded[2][2], "d")
  end)

  T.it("roundtrips CRLF line endings", function()
    local original = { { "x", "y" } }
    local encoded = csv.encode(original, { line_ending = "\r\n" })
    local decoded = csv.decode(encoded)
    T.eq(#decoded, 1)
    T.eq(decoded[1][1], "x")
    T.eq(decoded[1][2], "y")
  end)
end)

-- ===========================================================================
-- csv.iter
-- ===========================================================================

T.describe("csv.iter", function()
  T.it("iterates rows one at a time", function()
    local count = 0
    local results = {}
    for row in csv.iter("a,b\nc,d\ne,f\n") do
      count = count + 1
      results[count] = row
    end
    T.eq(count, 3)
    T.eq(results[1][1], "a")
    T.eq(results[2][1], "c")
    T.eq(results[3][1], "e")
  end)

  T.it("iter with single row", function()
    local rows = {}
    for row in csv.iter("hello,world\n") do
      rows[#rows + 1] = row
    end
    T.eq(#rows, 1)
    T.eq(rows[1][1], "hello")
    T.eq(rows[1][2], "world")
  end)

  T.it("iter with no trailing newline", function()
    local rows = {}
    for row in csv.iter("a,b") do rows[#rows + 1] = row end
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a")
  end)

  T.it("iter with separator option", function()
    local rows = {}
    for row in csv.iter("a;b\nc;d\n", { separator = ";" }) do
      rows[#rows + 1] = row
    end
    T.eq(#rows, 2)
    T.eq(rows[1][2], "b")
    T.eq(rows[2][2], "d")
  end)

  T.it("iter over empty string yields nothing", function()
    local count = 0
    for _ in csv.iter("") do count = count + 1 end
    T.eq(count, 0)
  end)
end)

-- ===========================================================================
-- csv.decoder (streaming, push-based)
-- ===========================================================================

T.describe("csv.decoder streaming", function()
  T.it("processes chunks and returns completed rows", function()
    local d = csv.decoder()
    d:push("a,b\nc")
    local rows = d:rows()
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a")
    T.eq(rows[1][2], "b")

    d:push(",d\n")
    rows = d:rows()
    T.eq(#rows, 1)
    T.eq(rows[1][1], "c")
    T.eq(rows[1][2], "d")
  end)

  T.it("handles data split across chunks", function()
    local d = csv.decoder()
    d:push("hel")
    d:push("lo,wor")
    d:push("ld\n")
    local rows = d:rows()
    T.eq(#rows, 1)
    T.eq(rows[1][1], "hello")
    T.eq(rows[1][2], "world")
  end)

  T.it("finish processes remaining buffer", function()
    local d = csv.decoder()
    d:push("a,b")
    local rows = d:rows()
    T.eq(#rows, 0)

    rows = d:finish()
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a")
    T.eq(rows[1][2], "b")
  end)

  T.it("handles quoted fields across chunks", function()
    local d = csv.decoder()
    d:push('"a,')
    d:push('b",c\n')
    local rows = d:rows()
    T.eq(#rows, 1)
    T.eq(rows[1][1], "a,b")
    T.eq(rows[1][2], "c")
  end)

  T.it("streaming with headers mode", function()
    local d = csv.decoder({ headers = true })
    d:push("name,age\nAlice,30\n")
    local rows = d:rows()
    T.eq(#rows, 1)
    T.eq(rows[1].name, "Alice")
    T.eq(rows[1].age, "30")
  end)

  T.it("multiple pushes then finish returns all rows", function()
    local d = csv.decoder()
    d:push("r1c1,r1c2\n")
    d:push("r2c1,r2c2\n")
    d:push("r3c1")
    -- rows() not called between pushes, so all 3 rows accumulate
    local rows = d:finish()
    T.eq(#rows, 3)
    T.eq(rows[1][1], "r1c1")
    T.eq(rows[2][1], "r2c1")
    T.eq(rows[3][1], "r3c1")
  end)
end)

-- ===========================================================================
-- Aliases
-- ===========================================================================

T.describe("csv aliases", function()
  T.it("string_to_rows is decode", function()
    T.eq(csv.string_to_rows, csv.decode)
  end)

  T.it("rows_to_string is encode", function()
    T.eq(csv.rows_to_string, csv.encode)
  end)

  T.it("M._tier is pure", function()
    T.eq(csv._tier, "pure")
  end)
end)
