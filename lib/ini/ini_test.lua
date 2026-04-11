if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local ini = require("lib.ini")

T.describe("ini._tier", function()
  T.it("is pure", function()
    T.eq(ini._tier, "pure")
  end)
end)

T.describe("ini.decode — global keys", function()
  T.it("parses a single global key", function()
    local t, err = ini.decode("key = value\n")
    T.eq(err, nil)
    T.eq(t.key, "value")
  end)

  T.it("parses multiple global keys", function()
    local t, err = ini.decode("key = value\nbare = noquotes\n")
    T.eq(err, nil)
    T.eq(t.key, "value")
    T.eq(t.bare, "noquotes")
  end)

  T.it("trims whitespace from keys and values", function()
    local t, err = ini.decode("  key  =  value  \n")
    T.eq(err, nil)
    T.eq(t.key, "value")
  end)

  T.it("parses empty value", function()
    local t, err = ini.decode("empty =\n")
    T.eq(err, nil)
    T.eq(t.empty, "")
  end)

  T.it("parses value with spaces", function()
    local t, err = ini.decode("msg = hello world\n")
    T.eq(err, nil)
    T.eq(t.msg, "hello world")
  end)
end)

T.describe("ini.decode — sections", function()
  T.it("parses a section with keys", function()
    local t, err = ini.decode("[section1]\nkey1 = value1\nkey2 = value2\n")
    T.eq(err, nil)
    T.ok(type(t.section1) == "table")
    T.eq(t.section1.key1, "value1")
    T.eq(t.section1.key2, "value2")
  end)

  T.it("parses multiple sections", function()
    local t, err = ini.decode("[s1]\na = 1\n[s2]\nb = 2\n")
    T.eq(err, nil)
    T.eq(t.s1.a, "1")
    T.eq(t.s2.b, "2")
  end)

  T.it("global keys before sections remain at top level", function()
    local t, err = ini.decode("top = yes\n[sec]\nx = 1\n")
    T.eq(err, nil)
    T.eq(t.top, "yes")
    T.eq(t.sec.x, "1")
  end)

  T.it("section names are case-preserved by default", function()
    local t, err = ini.decode("[MySection]\nk = v\n")
    T.eq(err, nil)
    T.ok(type(t.MySection) == "table")
    T.eq(t.MySection.k, "v")
  end)
end)

T.describe("ini.decode — comments", function()
  T.it("ignores semicolon comments", function()
    local t, err = ini.decode("; this is a comment\nkey = val\n")
    T.eq(err, nil)
    T.eq(t.key, "val")
  end)

  T.it("ignores hash comments", function()
    local t, err = ini.decode("# also a comment\nkey = val\n")
    T.eq(err, nil)
    T.eq(t.key, "val")
  end)

  T.it("strips inline semicolon comments from values", function()
    local t, err = ini.decode("key = value ; comment here\n")
    T.eq(err, nil)
    T.eq(t.key, "value")
  end)

  T.it("strips inline hash comments from values", function()
    local t, err = ini.decode("key = value # comment here\n")
    T.eq(err, nil)
    T.eq(t.key, "value")
  end)

  T.it("does not strip inline comment inside quoted value", function()
    local t, err = ini.decode('key = "value ; not a comment"\n')
    T.eq(err, nil)
    T.eq(t.key, "value ; not a comment")
  end)
end)

T.describe("ini.decode — quoted values", function()
  T.it("strips double quotes", function()
    local t, err = ini.decode('key = "hello world"\n')
    T.eq(err, nil)
    T.eq(t.key, "hello world")
  end)

  T.it("preserves = inside quoted value", function()
    local t, err = ini.decode('key = "a=b"\n')
    T.eq(err, nil)
    T.eq(t.key, "a=b")
  end)

  T.it("handles empty quoted value", function()
    local t, err = ini.decode('key = ""\n')
    T.eq(err, nil)
    T.eq(t.key, "")
  end)
end)

T.describe("ini.decode — opts.lowercase", function()
  T.it("lowercases section names", function()
    local t, err = ini.decode("[MySection]\nk = v\n", { lowercase = true })
    T.eq(err, nil)
    T.ok(type(t.mysection) == "table")
    T.eq(t.mysection.k, "v")
  end)

  T.it("lowercases keys", function()
    local t, err = ini.decode("MyKey = val\n", { lowercase = true })
    T.eq(err, nil)
    T.eq(t.mykey, "val")
  end)

  T.it("lowercases section keys", function()
    local t, err = ini.decode("[Sec]\nUpperKey = val\n", { lowercase = true })
    T.eq(err, nil)
    T.eq(t.sec.upperkey, "val")
  end)
end)

T.describe("ini.decode — opts.coerce", function()
  T.it("coerces integer strings to numbers", function()
    local t, err = ini.decode("n = 42\n", { coerce = true })
    T.eq(err, nil)
    T.eq(t.n, 42)
    T.ok(type(t.n) == "number")
  end)

  T.it("coerces float strings to numbers", function()
    local t, err = ini.decode("f = 3.14\n", { coerce = true })
    T.eq(err, nil)
    T.eq(t.f, 3.14)
    T.ok(type(t.f) == "number")
  end)

  T.it("coerces 'true' to boolean true", function()
    local t, err = ini.decode("b = true\n", { coerce = true })
    T.eq(err, nil)
    T.eq(t.b, true)
    T.ok(type(t.b) == "boolean")
  end)

  T.it("coerces 'false' to boolean false", function()
    local t, err = ini.decode("b = false\n", { coerce = true })
    T.eq(err, nil)
    T.eq(t.b, false)
    T.ok(type(t.b) == "boolean")
  end)

  T.it("leaves non-coercible strings as strings", function()
    local t, err = ini.decode("s = hello\n", { coerce = true })
    T.eq(err, nil)
    T.eq(t.s, "hello")
    T.ok(type(t.s) == "string")
  end)
end)

T.describe("ini.decode — last value wins", function()
  T.it("duplicate key uses last value", function()
    local t, err = ini.decode("key = first\nkey = second\n")
    T.eq(err, nil)
    T.eq(t.key, "second")
  end)
end)

T.describe("ini.decode — blank lines", function()
  T.it("ignores blank lines", function()
    local t, err = ini.decode("\n\nkey = val\n\n")
    T.eq(err, nil)
    T.eq(t.key, "val")
  end)
end)

T.describe("ini.decode — error cases", function()
  T.it("returns error for non-string input", function()
    local t, err = ini.decode(42)
    T.eq(t, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns error for malformed section header", function()
    local t, err = ini.decode("[unclosed\nkey = val\n")
    T.eq(t, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns error for line without =", function()
    local t, err = ini.decode("badline\n")
    T.eq(t, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns error for empty key", function()
    local t, err = ini.decode(" = value\n")
    T.eq(t, nil)
    T.ok(type(err) == "string")
  end)
end)

T.describe("ini.encode — global keys", function()
  T.it("encodes a single global key", function()
    local s, err = ini.encode({ key = "value" })
    T.eq(err, nil)
    T.ok(s:find("key = value") ~= nil)
  end)

  T.it("quotes values containing =", function()
    local s, err = ini.encode({ key = "a=b" })
    T.eq(err, nil)
    T.ok(s:find('"a=b"') ~= nil)
  end)

  T.it("quotes values containing ;", function()
    local s, err = ini.encode({ key = "a;b" })
    T.eq(err, nil)
    T.ok(s:find('"a;b"') ~= nil)
  end)

  T.it("quotes values containing #", function()
    local s, err = ini.encode({ key = "a#b" })
    T.eq(err, nil)
    T.ok(s:find('"a#b"') ~= nil)
  end)
end)

T.describe("ini.encode — sections", function()
  T.it("encodes a section header", function()
    local s, err = ini.encode({ sec = { k = "v" } })
    T.eq(err, nil)
    T.ok(s:find("%[sec%]") ~= nil)
    T.ok(s:find("k = v") ~= nil)
  end)

  T.it("returns error for non-table input", function()
    local s, err = ini.encode("not a table")
    T.eq(s, nil)
    T.ok(type(err) == "string")
  end)
end)

T.describe("ini.encode — opts.sort", function()
  T.it("sorts keys when opts.sort = true", function()
    local s, err = ini.encode({ z = "1", a = "2", m = "3" }, { sort = true })
    T.eq(err, nil)
    local pa = s:find("a = ")
    local pm = s:find("m = ")
    local pz = s:find("z = ")
    T.ok(pa ~= nil and pm ~= nil and pz ~= nil)
    T.ok(pa < pm and pm < pz)
  end)
end)

T.describe("ini — round-trip", function()
  T.it("decode then encode preserves values", function()
    local src = "[section1]\nkey1 = value1\nkey2 = value2\n"
    local t, err = ini.decode(src)
    T.eq(err, nil)
    local s, err2 = ini.encode(t)
    T.eq(err2, nil)
    -- re-decode the encoded string and check values
    local t2, err3 = ini.decode(s)
    T.eq(err3, nil)
    T.eq(t2.section1.key1, "value1")
    T.eq(t2.section1.key2, "value2")
  end)

  T.it("round-trips global keys", function()
    local t, err = ini.decode("foo = bar\nbaz = qux\n")
    T.eq(err, nil)
    local s, err2 = ini.encode(t)
    T.eq(err2, nil)
    local t2, err3 = ini.decode(s)
    T.eq(err3, nil)
    T.eq(t2.foo, "bar")
    T.eq(t2.baz, "qux")
  end)

  T.it("round-trips values containing = (via quoting)", function()
    local t, err = ini.decode('key = "a=b"\n')
    T.eq(err, nil)
    T.eq(t.key, "a=b")
    local s, err2 = ini.encode(t)
    T.eq(err2, nil)
    local t2, err3 = ini.decode(s)
    T.eq(err3, nil)
    T.eq(t2.key, "a=b")
  end)
end)

T.describe("ini.get", function()
  local t = {
    top = "global",
    section1 = { key1 = "v1", key2 = "v2" },
  }

  T.it("gets a global key (section=nil)", function()
    T.eq(ini.get(t, nil, "top"), "global")
  end)

  T.it("gets a section key", function()
    T.eq(ini.get(t, "section1", "key1"), "v1")
  end)

  T.it("returns nil for missing section", function()
    T.eq(ini.get(t, "nosection", "key1"), nil)
  end)

  T.it("returns nil for missing key in section", function()
    T.eq(ini.get(t, "section1", "missing"), nil)
  end)

  T.it("returns nil for missing global key", function()
    T.eq(ini.get(t, nil, "missing"), nil)
  end)
end)

T.describe("ini.decode — full featured INI", function()
  T.it("parses a complex INI document", function()
    local src = [[
; This is a comment
# This is also a comment

key = value
bare = noquotes

[section1]
key1 = value1
key2 = value with spaces
quoted = "value with = sign"

[section2]
number = 42
bool = true
empty =
]]
    local t, err = ini.decode(src)
    T.eq(err, nil)
    T.eq(t.key, "value")
    T.eq(t.bare, "noquotes")
    T.ok(type(t.section1) == "table")
    T.eq(t.section1.key1, "value1")
    T.eq(t.section1.key2, "value with spaces")
    T.eq(t.section1.quoted, "value with = sign")
    T.ok(type(t.section2) == "table")
    T.eq(t.section2.number, "42")
    T.eq(t.section2.bool, "true")
    T.eq(t.section2.empty, "")
  end)

  T.it("parses a complex INI with coerce", function()
    local src = "[s]\nnumber = 42\nbool = true\nflag = false\n"
    local t, err = ini.decode(src, { coerce = true })
    T.eq(err, nil)
    T.eq(t.s.number, 42)
    T.eq(t.s.bool, true)
    T.eq(t.s.flag, false)
  end)
end)

T.describe("ini aliases", function()
  T.it("M.parse is M.decode", function()
    T.ok(ini.parse == ini.decode)
  end)

  T.it("M.string_to_table is M.decode", function()
    T.ok(ini.string_to_table == ini.decode)
  end)

  T.it("M.stringify is M.encode", function()
    T.ok(ini.stringify == ini.encode)
  end)

  T.it("M.table_to_string is M.encode", function()
    T.ok(ini.table_to_string == ini.encode)
  end)
end)
