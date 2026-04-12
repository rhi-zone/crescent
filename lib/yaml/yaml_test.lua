if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local yaml = require("lib.yaml")

-- ---------------------------------------------------------------------------
T.describe("yaml module", function()

  T.it("has _tier = pure", function()
    T.eq(yaml._tier, "pure")
  end)

  T.it("has decode/parse/encode/stringify aliases", function()
    T.eq(type(yaml.decode),    "function")
    T.eq(type(yaml.parse),     "function")
    T.eq(type(yaml.encode),    "function")
    T.eq(type(yaml.stringify), "function")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("decode scalars", function()

  T.it("parses plain string", function()
    local v = yaml.decode("hello")
    T.eq(v, "hello")
  end)

  T.it("parses integer", function()
    T.eq(yaml.decode("42"),  42)
    T.eq(yaml.decode("-7"),  -7)
    T.eq(yaml.decode("0"),    0)
  end)

  T.it("parses float", function()
    T.eq(yaml.decode("3.14"),  3.14)
    T.eq(yaml.decode("-0.5"), -0.5)
    T.eq(yaml.decode("1e3"),   1000.0)
  end)

  T.it("parses booleans", function()
    T.eq(yaml.decode("true"),  true)
    T.eq(yaml.decode("false"), false)
    T.eq(yaml.decode("yes"),   true)
    T.eq(yaml.decode("no"),    false)
    T.eq(yaml.decode("on"),    true)
    T.eq(yaml.decode("off"),   false)
  end)

  T.it("parses null variants", function()
    T.eq(yaml.decode("null"), nil)
    T.eq(yaml.decode("~"),    nil)
  end)

  T.it("parses double-quoted string", function()
    T.eq(yaml.decode('"hello world"'), "hello world")
    T.eq(yaml.decode('"with \\"quotes\\""'), 'with "quotes"')
    T.eq(yaml.decode('"line\\nbreak"'), "line\nbreak")
    T.eq(yaml.decode('"tab\\there"'), "tab\there")
  end)

  T.it("parses single-quoted string", function()
    T.eq(yaml.decode("'hello'"), "hello")
    T.eq(yaml.decode("'it''s'"), "it's")
    T.eq(yaml.decode("'no escape \\n'"), "no escape \\n")
  end)

  T.it("parses special float values", function()
    T.eq(yaml.decode(".inf"),  math.huge)
    T.eq(yaml.decode("-.inf"), -math.huge)
    local nan = yaml.decode(".nan")
    T.ok(nan ~= nan, "NaN should not equal itself")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("decode block sequences", function()

  T.it("parses simple sequence", function()
    local v = yaml.decode("- a\n- b\n- c\n")
    T.eq(type(v), "table")
    T.eq(#v, 3)
    T.eq(v[1], "a")
    T.eq(v[2], "b")
    T.eq(v[3], "c")
  end)

  T.it("parses sequence of numbers", function()
    local v = yaml.decode("- 1\n- 2\n- 3\n")
    T.eq(v[1], 1)
    T.eq(v[2], 2)
    T.eq(v[3], 3)
  end)

  T.it("parses empty sequence element (null)", function()
    local v = yaml.decode("- null\n- b\n")
    T.eq(v[1], nil)
    T.eq(v[2], "b")
  end)

  T.it("parses nested sequences", function()
    local v = yaml.decode("- - x\n  - y\n- - z\n")
    T.eq(type(v[1]), "table")
    T.eq(v[1][1], "x")
    T.eq(v[1][2], "y")
    T.eq(v[2][1], "z")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("decode block mappings", function()

  T.it("parses simple mapping", function()
    local v = yaml.decode("name: Alice\nage: 30\n")
    T.eq(v.name, "Alice")
    T.eq(v.age, 30)
  end)

  T.it("parses nested mapping", function()
    local v = yaml.decode("person:\n  name: Bob\n  age: 25\n")
    T.eq(type(v.person), "table")
    T.eq(v.person.name, "Bob")
    T.eq(v.person.age, 25)
  end)

  T.it("parses mapping with bool/null values", function()
    local v = yaml.decode("active: true\ndeleted: null\n")
    T.eq(v.active, true)
    T.eq(v.deleted, nil)
  end)

  T.it("parses mapping with quoted keys", function()
    local v = yaml.decode('"key with spaces": value\n')
    T.eq(v["key with spaces"], "value")
  end)

  T.it("parses sequence inside mapping", function()
    local v = yaml.decode("tags:\n  - lua\n  - yaml\n")
    T.eq(type(v.tags), "table")
    T.eq(v.tags[1], "lua")
    T.eq(v.tags[2], "yaml")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("decode flow collections", function()

  T.it("parses flow sequence", function()
    local v = yaml.decode("[1, 2, 3]")
    T.eq(#v, 3)
    T.eq(v[1], 1)
    T.eq(v[2], 2)
    T.eq(v[3], 3)
  end)

  T.it("parses flow sequence with strings", function()
    local v = yaml.decode("[a, b, c]")
    T.eq(v[1], "a")
    T.eq(v[2], "b")
    T.eq(v[3], "c")
  end)

  T.it("parses empty flow sequence", function()
    local v = yaml.decode("[]")
    T.eq(type(v), "table")
    T.eq(#v, 0)
  end)

  T.it("parses flow mapping", function()
    local v = yaml.decode("{x: 1, y: 2}")
    T.eq(v.x, 1)
    T.eq(v.y, 2)
  end)

  T.it("parses empty flow mapping", function()
    local v = yaml.decode("{}")
    T.eq(type(v), "table")
    T.eq(next(v), nil)
  end)

  T.it("parses nested flow", function()
    local v = yaml.decode("{a: [1, 2], b: {c: 3}}")
    T.eq(v.a[1], 1)
    T.eq(v.a[2], 2)
    T.eq(v.b.c, 3)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("comments", function()

  T.it("ignores line comments", function()
    local v = yaml.decode("# this is a comment\nvalue: hello # inline\n")
    T.eq(v.value, "hello")
  end)

  T.it("ignores leading comment", function()
    local v = yaml.decode("# header\nfoo: bar\n")
    T.eq(v.foo, "bar")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("document markers", function()

  T.it("handles document start marker", function()
    local v = yaml.decode("---\nfoo: bar\n")
    T.eq(v.foo, "bar")
  end)

  T.it("handles document start in sequence", function()
    local v = yaml.decode("---\n- a\n- b\n")
    T.eq(v[1], "a")
    T.eq(v[2], "b")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("anchors and aliases", function()

  T.it("resolves simple anchor/alias", function()
    local v = yaml.decode("base: &anchor hello\nref: *anchor\n")
    T.eq(v.base, "hello")
    T.eq(v.ref,  "hello")
  end)

  T.it("resolves anchor to table", function()
    local v = yaml.decode("a: &tbl\n  x: 1\n  y: 2\nb: *tbl\n")
    T.eq(v.a.x, 1)
    T.eq(v.b.x, 1)
    T.ok(v.a == v.b, "should be same table reference")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("block scalars", function()

  T.it("parses literal block scalar |", function()
    local v = yaml.decode("text: |\n  line one\n  line two\n")
    T.eq(v.text, "line one\nline two\n")
  end)

  T.it("parses literal block scalar with strip |−", function()
    local v = yaml.decode("text: |-\n  line one\n  line two\n")
    T.eq(v.text, "line one\nline two")
  end)

  T.it("parses literal block scalar with keep |+", function()
    local v = yaml.decode("text: |+\n  hello\n\n\n")
    T.ok(v.text:find("hello") ~= nil)
    -- keep trailing newlines
    T.ok(#v.text > #"hello\n")
  end)

  T.it("parses folded block scalar >", function()
    local v = yaml.decode("text: >\n  folded\n  line\n")
    T.eq(v.text, "folded line\n")
  end)

  T.it("parses folded block scalar with strip >-", function()
    local v = yaml.decode("text: >-\n  folded\n  text\n")
    T.eq(v.text, "folded text")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("encode scalars", function()

  T.it("encodes string", function()
    local s = yaml.encode("hello")
    T.eq(s, "hello")
  end)

  T.it("encodes integer", function()
    T.eq(yaml.encode(42),  "42")
    T.eq(yaml.encode(-7),  "-7")
    T.eq(yaml.encode(0),   "0")
  end)

  T.it("encodes float", function()
    local s = yaml.encode(3.14)
    T.ok(s ~= nil)
    T.ok(s:find("3") ~= nil)
  end)

  T.it("encodes boolean", function()
    T.eq(yaml.encode(true),  "true")
    T.eq(yaml.encode(false), "false")
  end)

  T.it("encodes nil as null", function()
    T.eq(yaml.encode(nil), "null")
  end)

  T.it("quotes strings that look like booleans", function()
    local s = yaml.encode("true")
    T.ok(s:find('"') ~= nil, "should be quoted: " .. tostring(s))
  end)

  T.it("quotes strings that look like numbers", function()
    local s = yaml.encode("42")
    T.ok(s:find('"') ~= nil, "should be quoted: " .. tostring(s))
  end)

  T.it("quotes strings with colon-space", function()
    local s = yaml.encode("key: value")
    T.ok(s:find('"') ~= nil, "should be quoted")
  end)

  T.it("encodes special float values", function()
    T.eq(yaml.encode(math.huge),  ".inf")
    T.eq(yaml.encode(-math.huge), "-.inf")
    T.eq(yaml.encode(0/0),        ".nan")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("encode tables", function()

  T.it("encodes array", function()
    local s = yaml.encode({"a", "b", "c"})
    T.ok(s:find("- a") ~= nil)
    T.ok(s:find("- b") ~= nil)
    T.ok(s:find("- c") ~= nil)
  end)

  T.it("encodes mapping", function()
    local s = yaml.encode({name = "Alice", age = 30})
    T.ok(s:find("name: Alice") ~= nil)
    T.ok(s:find("age: 30") ~= nil)
  end)

  T.it("encodes nested mapping", function()
    local s = yaml.encode({person = {name = "Bob", age = 25}})
    T.ok(s:find("person:") ~= nil)
    T.ok(s:find("name: Bob") ~= nil)
    T.ok(s:find("age: 25") ~= nil)
  end)

  T.it("encodes empty table as {}", function()
    T.eq(yaml.encode({}), "{}")
  end)

  T.it("sort_keys produces deterministic output", function()
    local t = {z = 3, a = 1, m = 2}
    local s1 = yaml.encode(t, {sort_keys = true})
    local s2 = yaml.encode(t, {sort_keys = true})
    T.eq(s1, s2)
    -- a should come before m, m before z
    local pa = s1:find("a:")
    local pm = s1:find("m:")
    local pz = s1:find("z:")
    T.ok(pa < pm, "a before m")
    T.ok(pm < pz, "m before z")
  end)

  T.it("respects indent option", function()
    local s = yaml.encode({a = {b = 1}}, {indent = 4})
    T.ok(s:find("    b: 1") ~= nil, "4-space indent: " .. tostring(s))
  end)

end)

-- Round-trip helper (module scope so edge-cases describe can use it too)
local function rt(val, opts)
  local encoded, err1 = yaml.encode(val, opts)
  if not encoded then return nil, err1 end
  local decoded, err2 = yaml.decode(encoded)
  if err2 then return nil, err2 end
  return decoded
end

-- ---------------------------------------------------------------------------
T.describe("round-trip", function()

  T.it("round-trips string", function()
    T.eq(rt("hello"),      "hello")
    T.eq(rt("with spaces"),"with spaces")
  end)

  T.it("round-trips numbers", function()
    T.eq(rt(42),   42)
    T.eq(rt(-7),   -7)
    T.eq(rt(0),    0)
    T.eq(rt(3.14), 3.14)
  end)

  T.it("round-trips booleans", function()
    T.eq(rt(true),  true)
    T.eq(rt(false), false)
  end)

  T.it("round-trips null", function()
    T.eq(rt(nil), nil)
  end)

  T.it("round-trips simple array", function()
    local v = rt({1, 2, 3})
    T.eq(v[1], 1)
    T.eq(v[2], 2)
    T.eq(v[3], 3)
  end)

  T.it("round-trips nested array", function()
    local v = rt({{1, 2}, {3, 4}})
    T.eq(v[1][1], 1)
    T.eq(v[1][2], 2)
    T.eq(v[2][1], 3)
    T.eq(v[2][2], 4)
  end)

  T.it("round-trips mapping", function()
    local v = rt({name = "Alice", age = 30}, {sort_keys = true})
    T.eq(v.name, "Alice")
    T.eq(v.age,  30)
  end)

  T.it("round-trips nested mapping", function()
    local v = rt({a = {b = {c = "deep"}}}, {sort_keys = true})
    T.eq(v.a.b.c, "deep")
  end)

  T.it("round-trips mixed array/map", function()
    local v = rt({items = {"x", "y"}, count = 2}, {sort_keys = true})
    T.eq(v.count,    2)
    T.eq(v.items[1], "x")
    T.eq(v.items[2], "y")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("edge cases", function()

  T.it("decodes empty string as nil", function()
    local v = yaml.decode("")
    T.eq(v, nil)
  end)

  T.it("decodes only whitespace as nil", function()
    local v = yaml.decode("   \n  ")
    T.eq(v, nil)
  end)

  T.it("decodes only comment as nil", function()
    local v = yaml.decode("# just a comment\n")
    T.eq(v, nil)
  end)

  T.it("decode returns nil,errmsg on non-string", function()
    local v, err = yaml.decode(123)
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(type(err) == "string")
  end)

  T.it("handles string with special chars via quoting", function()
    local v = rt("hello: world")
    T.eq(v, "hello: world")
  end)

  T.it("handles string that looks like null", function()
    local v = rt("null")
    T.eq(v, "null")
  end)

  T.it("handles string that looks like bool", function()
    local v = rt("true")
    T.eq(v, "true")
  end)

  T.it("handles multiline values in mapping", function()
    local v = yaml.decode("a: 1\nb: 2\nc: 3\n")
    T.eq(v.a, 1)
    T.eq(v.b, 2)
    T.eq(v.c, 3)
  end)

  T.it("handles deeply nested structure", function()
    local v = yaml.decode("l1:\n  l2:\n    l3:\n      val: deep\n")
    T.eq(v.l1.l2.l3.val, "deep")
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("encode alias", function()

  T.it("stringify is alias for encode", function()
    T.eq(yaml.stringify("hello"), yaml.encode("hello"))
    T.eq(yaml.stringify(42),      yaml.encode(42))
    T.eq(yaml.stringify(true),    yaml.encode(true))
  end)

end)
