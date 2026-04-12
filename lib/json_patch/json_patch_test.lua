-- lib/json_patch/json_patch_test.lua
-- Tests for RFC 6901 JSON Pointer and RFC 6902 JSON Patch.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local JP = require("lib.json_patch")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function ops_to_simple(ops)
  -- Return just the op/path/value fields for comparison
  local out = {}
  for _, op in ipairs(ops) do out[#out+1] = op end
  return out
end

-- ---------------------------------------------------------------------------
-- JSON Pointer: escape / unescape
-- ---------------------------------------------------------------------------

T.describe("JP.escape / JP.unescape", function()
  T.it("escape: tilde", function()
    T.eq(JP.escape("a~b"), "a~0b")
  end)
  T.it("escape: slash", function()
    T.eq(JP.escape("a/b"), "a~1b")
  end)
  T.it("escape: both", function()
    T.eq(JP.escape("a~/b"), "a~0~1b")
  end)
  T.it("escape: no special chars", function()
    T.eq(JP.escape("foo"), "foo")
  end)
  T.it("unescape: ~1 → /", function()
    T.eq(JP.unescape("a~1b"), "a/b")
  end)
  T.it("unescape: ~0 → ~", function()
    T.eq(JP.unescape("a~0b"), "a~b")
  end)
  T.it("unescape: both in order", function()
    -- ~01 → first ~0 then 1 → "~1" then that should NOT be re-processed
    -- ~01 unescape: ~0 → ~, then ~1 → /   (two separate passes)
    -- Actually the spec says replace ~1 first then ~0.
    -- ~01: first pass replace ~1 → no ~1 here. Second pass replace ~0 → ~. Result: ~1
    -- Wait: "~01" — ~0 replaces to ~, leaving "~1" which was already processed.
    -- Per spec (section 3): ~1 first, then ~0.
    -- "~01" has no ~1, so stays "~01"; then ~0 → ~, giving "~1".
    T.eq(JP.unescape("~01"), "~1")
  end)
  T.it("round-trip", function()
    local tok = "hello/world~test"
    T.eq(JP.unescape(JP.escape(tok)), tok)
  end)
end)

-- ---------------------------------------------------------------------------
-- JSON Pointer: parse / build
-- ---------------------------------------------------------------------------

T.describe("JP.parse / JP.build", function()
  T.it("parse root", function()
    local parts = JP.parse("")
    T.eq(#parts, 0)
  end)
  T.it("parse single", function()
    local parts = JP.parse("/foo")
    T.eq(#parts, 1)
    T.eq(parts[1], "foo")
  end)
  T.it("parse nested", function()
    local parts = JP.parse("/foo/bar/0")
    T.eq(#parts, 3)
    T.eq(parts[1], "foo")
    T.eq(parts[2], "bar")
    T.eq(parts[3], "0")
  end)
  T.it("parse with escaping", function()
    local parts = JP.parse("/a~1b/c~0d")
    T.eq(#parts, 2)
    T.eq(parts[1], "a/b")
    T.eq(parts[2], "c~d")
  end)
  T.it("parse error: no leading slash", function()
    local parts, err = JP.parse("foo/bar")
    T.eq(parts, nil)
    T.ok(err)
  end)
  T.it("build empty", function()
    T.eq(JP.build({}), "")
  end)
  T.it("build single", function()
    T.eq(JP.build({"foo"}), "/foo")
  end)
  T.it("build nested", function()
    T.eq(JP.build({"foo", "bar", "0"}), "/foo/bar/0")
  end)
  T.it("build with special chars", function()
    T.eq(JP.build({"a/b", "c~d"}), "/a~1b/c~0d")
  end)
  T.it("round-trip: parse then build", function()
    local ptr = "/foo/a~1b/c~0d/0"
    T.eq(JP.build(JP.parse(ptr)), ptr)
  end)
end)

-- ---------------------------------------------------------------------------
-- JSON Pointer: pointer_get
-- ---------------------------------------------------------------------------

T.describe("JP.pointer_get", function()
  local doc = {
    foo = { bar = { 42, 43, 44 } },
    baz = "hello",
    arr = { 10, 20, 30 },
    ["a/b"] = "slash",
    ["c~d"] = "tilde",
  }

  T.it("root pointer", function()
    local v, err = JP.pointer_get(doc, "")
    T.eq(err, nil)
    T.eq(v, doc)
  end)
  T.it("top-level key", function()
    local v, err = JP.pointer_get(doc, "/baz")
    T.eq(err, nil)
    T.eq(v, "hello")
  end)
  T.it("nested object", function()
    local v, err = JP.pointer_get(doc, "/foo/bar")
    T.eq(err, nil)
    T.ok(type(v) == "table")
    T.eq(v[1], 42)
  end)
  T.it("array index 0 → Lua 1", function()
    local v, err = JP.pointer_get(doc, "/foo/bar/0")
    T.eq(err, nil)
    T.eq(v, 42)
  end)
  T.it("array index 2", function()
    local v, err = JP.pointer_get(doc, "/arr/2")
    T.eq(err, nil)
    T.eq(v, 30)
  end)
  T.it("~1 escape resolves slash key", function()
    local v, err = JP.pointer_get(doc, "/a~1b")
    T.eq(err, nil)
    T.eq(v, "slash")
  end)
  T.it("~0 escape resolves tilde key", function()
    local v, err = JP.pointer_get(doc, "/c~0d")
    T.eq(err, nil)
    T.eq(v, "tilde")
  end)
  T.it("missing top-level key returns nil+err", function()
    local v, err = JP.pointer_get(doc, "/missing")
    T.eq(v, nil)
    T.ok(err)
  end)
  T.it("missing nested key returns nil+err", function()
    local v, err = JP.pointer_get(doc, "/foo/nope")
    T.eq(v, nil)
    T.ok(err)
  end)
  T.it("path through scalar returns nil+err", function()
    local v, err = JP.pointer_get(doc, "/baz/deep")
    T.eq(v, nil)
    T.ok(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- JSON Pointer: pointer_set
-- ---------------------------------------------------------------------------

T.describe("JP.pointer_set", function()
  T.it("set top-level key", function()
    local doc = { x = 1 }
    local ok, err = JP.pointer_set(doc, "/x", 99)
    T.eq(err, nil)
    T.eq(ok, true)
    T.eq(doc.x, 99)
  end)
  T.it("create new key", function()
    local doc = { x = 1 }
    local ok, err = JP.pointer_set(doc, "/y", "new")
    T.eq(err, nil)
    T.eq(ok, true)
    T.eq(doc.y, "new")
  end)
  T.it("set nested key", function()
    local doc = { a = { b = 5 } }
    local ok, err = JP.pointer_set(doc, "/a/b", 100)
    T.eq(err, nil)
    T.eq(ok, true)
    T.eq(doc.a.b, 100)
  end)
  T.it("set array element", function()
    local doc = { arr = { 1, 2, 3 } }
    local ok, err = JP.pointer_set(doc, "/arr/1", 99)
    T.eq(err, nil)
    T.eq(ok, true)
    T.eq(doc.arr[2], 99)  -- JSON 1 → Lua 2
  end)
  T.it("missing intermediate path returns error", function()
    local doc = { a = 1 }
    local ok, err = JP.pointer_set(doc, "/a/b", 5)
    T.eq(ok, nil)
    T.ok(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- JSON Pointer: pointer_del
-- ---------------------------------------------------------------------------

T.describe("JP.pointer_del", function()
  T.it("delete object key", function()
    local doc = { x = 1, y = 2 }
    local ok, err = JP.pointer_del(doc, "/x")
    T.eq(err, nil)
    T.eq(ok, true)
    T.eq(doc.x, nil)
    T.eq(doc.y, 2)
  end)
  T.it("delete array element shifts others", function()
    local doc = { arr = { 10, 20, 30 } }
    local ok, err = JP.pointer_del(doc, "/arr/0")  -- remove index 0 (Lua 1)
    T.eq(err, nil)
    T.eq(ok, true)
    T.eq(#doc.arr, 2)
    T.eq(doc.arr[1], 20)
    T.eq(doc.arr[2], 30)
  end)
  T.it("delete nested key", function()
    local doc = { a = { b = 5, c = 6 } }
    local ok, err = JP.pointer_del(doc, "/a/b")
    T.eq(err, nil)
    T.eq(ok, true)
    T.eq(doc.a.b, nil)
    T.eq(doc.a.c, 6)
  end)
  T.it("delete missing key returns error", function()
    local doc = { x = 1 }
    local ok, err = JP.pointer_del(doc, "/missing")
    T.eq(ok, nil)
    T.ok(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- validate_patch
-- ---------------------------------------------------------------------------

T.describe("JP.validate_patch", function()
  T.it("valid add", function()
    local ok, err = JP.validate_patch({{ op = "add", path = "/foo", value = 1 }})
    T.eq(err, nil)
    T.eq(ok, true)
  end)
  T.it("valid remove", function()
    local ok, err = JP.validate_patch({{ op = "remove", path = "/foo" }})
    T.eq(err, nil)
    T.eq(ok, true)
  end)
  T.it("valid replace", function()
    local ok, err = JP.validate_patch({{ op = "replace", path = "/foo", value = 2 }})
    T.eq(err, nil)
    T.eq(ok, true)
  end)
  T.it("valid move", function()
    local ok, err = JP.validate_patch({{ op = "move", from = "/a", path = "/b" }})
    T.eq(err, nil)
    T.eq(ok, true)
  end)
  T.it("valid copy", function()
    local ok, err = JP.validate_patch({{ op = "copy", from = "/a", path = "/b" }})
    T.eq(err, nil)
    T.eq(ok, true)
  end)
  T.it("valid test", function()
    local ok, err = JP.validate_patch({{ op = "test", path = "/foo", value = 1 }})
    T.eq(err, nil)
    T.eq(ok, true)
  end)
  T.it("missing op", function()
    local ok, err = JP.validate_patch({{ path = "/foo", value = 1 }})
    T.eq(ok, nil)
    T.ok(err)
  end)
  T.it("unknown op", function()
    local ok, err = JP.validate_patch({{ op = "explode", path = "/foo" }})
    T.eq(ok, nil)
    T.ok(err)
  end)
  T.it("add missing value", function()
    local ok, err = JP.validate_patch({{ op = "add", path = "/foo" }})
    T.eq(ok, nil)
    T.ok(err)
  end)
  T.it("remove missing path", function()
    local ok, err = JP.validate_patch({{ op = "remove" }})
    T.eq(ok, nil)
    T.ok(err)
  end)
  T.it("non-table patch", function()
    local ok, err = JP.validate_patch("not a patch")
    T.eq(ok, nil)
    T.ok(err)
  end)
  T.it("empty patch is valid", function()
    local ok, err = JP.validate_patch({})
    T.eq(err, nil)
    T.eq(ok, true)
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: basic operations
-- ---------------------------------------------------------------------------

T.describe("JP.apply - add / remove / replace", function()
  T.it("add new key", function()
    local doc = { a = 1 }
    local res, err = JP.apply(doc, {{ op = "add", path = "/b", value = 2 }})
    T.eq(err, nil)
    T.eq(res.a, 1)
    T.eq(res.b, 2)
    -- original unmodified
    T.eq(doc.b, nil)
  end)
  T.it("add replaces existing key", function()
    local doc = { a = 1 }
    local res, err = JP.apply(doc, {{ op = "add", path = "/a", value = 99 }})
    T.eq(err, nil)
    T.eq(res.a, 99)
  end)
  T.it("remove key", function()
    local doc = { a = 1, b = 2 }
    local res, err = JP.apply(doc, {{ op = "remove", path = "/a" }})
    T.eq(err, nil)
    T.eq(res.a, nil)
    T.eq(res.b, 2)
  end)
  T.it("replace value", function()
    local doc = { a = 1 }
    local res, err = JP.apply(doc, {{ op = "replace", path = "/a", value = 42 }})
    T.eq(err, nil)
    T.eq(res.a, 42)
  end)
  T.it("replace nonexistent fails", function()
    local doc = { a = 1 }
    local res, err = JP.apply(doc, {{ op = "replace", path = "/z", value = 5 }})
    T.eq(res, nil)
    T.ok(err)
  end)
  T.it("remove nonexistent fails", function()
    local doc = { a = 1 }
    local res, err = JP.apply(doc, {{ op = "remove", path = "/z" }})
    T.eq(res, nil)
    T.ok(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: array operations
-- ---------------------------------------------------------------------------

T.describe("JP.apply - array operations", function()
  T.it("add at index inserts and shifts", function()
    local doc = { arr = { 1, 2, 3 } }
    local res, err = JP.apply(doc, {{ op = "add", path = "/arr/1", value = 99 }})
    T.eq(err, nil)
    T.eq(#res.arr, 4)
    T.eq(res.arr[1], 1)
    T.eq(res.arr[2], 99)
    T.eq(res.arr[3], 2)
    T.eq(res.arr[4], 3)
  end)
  T.it("add with '-' appends", function()
    local doc = { arr = { 1, 2, 3 } }
    local res, err = JP.apply(doc, {{ op = "add", path = "/arr/-", value = 4 }})
    T.eq(err, nil)
    T.eq(#res.arr, 4)
    T.eq(res.arr[4], 4)
  end)
  T.it("add at position 0 inserts at front", function()
    local doc = { arr = { 10, 20 } }
    local res, err = JP.apply(doc, {{ op = "add", path = "/arr/0", value = 5 }})
    T.eq(err, nil)
    T.eq(res.arr[1], 5)
    T.eq(res.arr[2], 10)
    T.eq(res.arr[3], 20)
  end)
  T.it("remove from array shifts elements", function()
    local doc = { arr = { 10, 20, 30 } }
    local res, err = JP.apply(doc, {{ op = "remove", path = "/arr/1" }})
    T.eq(err, nil)
    T.eq(#res.arr, 2)
    T.eq(res.arr[1], 10)
    T.eq(res.arr[2], 30)
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: move / copy
-- ---------------------------------------------------------------------------

T.describe("JP.apply - move / copy", function()
  T.it("move key", function()
    local doc = { a = { b = 1 }, c = 2 }
    local res, err = JP.apply(doc, {{ op = "move", from = "/a/b", path = "/c" }})
    T.eq(err, nil)
    T.eq(res.c, 1)
    T.eq(res.a.b, nil)
  end)
  T.it("copy key", function()
    local doc = { a = { x = 5 } }
    local res, err = JP.apply(doc, {{ op = "copy", from = "/a/x", path = "/b" }})
    T.eq(err, nil)
    T.eq(res.b, 5)
    T.eq(res.a.x, 5)  -- original still there
  end)
  T.it("copy is deep", function()
    local doc = { a = { nested = { v = 1 } } }
    local res, err = JP.apply(doc, {{ op = "copy", from = "/a", path = "/b" }})
    T.eq(err, nil)
    T.eq(res.b.nested.v, 1)
    -- Modifying result doesn't affect source
    res.b.nested.v = 99
    T.eq(res.a.nested.v, 1)
  end)
  T.it("move from missing fails", function()
    local doc = { a = 1 }
    local res, err = JP.apply(doc, {{ op = "move", from = "/z", path = "/b" }})
    T.eq(res, nil)
    T.ok(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: test op
-- ---------------------------------------------------------------------------

T.describe("JP.apply - test op", function()
  T.it("test succeeds when values match", function()
    local doc = { a = 1 }
    local res, err = JP.apply(doc, {{ op = "test", path = "/a", value = 1 }})
    T.eq(err, nil)
    T.eq(res.a, 1)
  end)
  T.it("test fails when values differ", function()
    local doc = { a = 1 }
    local res, err = JP.apply(doc, {{ op = "test", path = "/a", value = 2 }})
    T.eq(res, nil)
    T.ok(err)
  end)
  T.it("test with deep table equality", function()
    local doc = { a = { x = 1, y = 2 } }
    local res, err = JP.apply(doc, {{ op = "test", path = "/a", value = { x = 1, y = 2 } }})
    T.eq(err, nil)
    T.ok(res)
  end)
  T.it("test with deep table inequality", function()
    local doc = { a = { x = 1, y = 2 } }
    local res, err = JP.apply(doc, {{ op = "test", path = "/a", value = { x = 1, y = 3 } }})
    T.eq(res, nil)
    T.ok(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: atomicity
-- ---------------------------------------------------------------------------

T.describe("JP.apply - atomicity", function()
  T.it("bad op in middle leaves original unchanged", function()
    local doc = { a = 1, b = 2 }
    local res, err = JP.apply(doc, {
      { op = "add", path = "/c", value = 3 },
      { op = "remove", path = "/nonexistent" },  -- will fail
      { op = "add", path = "/d", value = 4 },
    })
    T.eq(res, nil)
    T.ok(err)
    -- original doc untouched
    T.eq(doc.a, 1)
    T.eq(doc.b, 2)
    T.eq(doc.c, nil)
    T.eq(doc.d, nil)
  end)
  T.it("test failure leaves original unchanged", function()
    local doc = { a = 1 }
    local res, err = JP.apply(doc, {
      { op = "add", path = "/b", value = 99 },
      { op = "test", path = "/a", value = 999 },  -- fails
    })
    T.eq(res, nil)
    T.ok(err)
    T.eq(doc.a, 1)
    T.eq(doc.b, nil)
  end)
  T.it("successful patch returns new doc, original unchanged", function()
    local doc = { a = 1 }
    local res, err = JP.apply(doc, {{ op = "add", path = "/b", value = 2 }})
    T.eq(err, nil)
    T.eq(res.a, 1)
    T.eq(res.b, 2)
    T.eq(doc.b, nil)  -- original untouched
  end)
end)

-- ---------------------------------------------------------------------------
-- diff
-- ---------------------------------------------------------------------------

T.describe("JP.diff", function()
  T.it("identical docs → empty patch", function()
    local a = { x = 1, y = 2 }
    local patch = JP.diff(a, { x = 1, y = 2 })
    T.eq(#patch, 0)
  end)
  T.it("diff produces patch that transforms a into b (flat object)", function()
    local a = { x = 1, y = 2 }
    local b = { x = 1, y = 3, z = 4 }
    local patch = JP.diff(a, b)
    local res, err = JP.apply(a, patch)
    T.eq(err, nil)
    T.ok(JP.deep_equal(res, b))
  end)
  T.it("diff produces patch for removed key", function()
    local a = { x = 1, y = 2 }
    local b = { x = 1 }
    local patch = JP.diff(a, b)
    local res, err = JP.apply(a, patch)
    T.eq(err, nil)
    T.ok(JP.deep_equal(res, b))
  end)
  T.it("diff nested object changes", function()
    local a = { a = { b = 1, c = 2 } }
    local b = { a = { b = 99, d = 3 } }
    local patch = JP.diff(a, b)
    local res, err = JP.apply(a, patch)
    T.eq(err, nil)
    T.ok(JP.deep_equal(res, b))
  end)
  T.it("diff array: elements added", function()
    local a = { arr = { 1, 2, 3 } }
    local b = { arr = { 1, 2, 3, 4, 5 } }
    local patch = JP.diff(a, b)
    local res, err = JP.apply(a, patch)
    T.eq(err, nil)
    T.ok(JP.deep_equal(res, b))
  end)
  T.it("diff array: elements removed", function()
    local a = { arr = { 1, 2, 3, 4 } }
    local b = { arr = { 1, 4 } }
    local patch = JP.diff(a, b)
    local res, err = JP.apply(a, patch)
    T.eq(err, nil)
    T.ok(JP.deep_equal(res, b))
  end)
  T.it("diff array: element changed", function()
    local a = { arr = { 10, 20, 30 } }
    local b = { arr = { 10, 99, 30 } }
    local patch = JP.diff(a, b)
    local res, err = JP.apply(a, patch)
    T.eq(err, nil)
    T.ok(JP.deep_equal(res, b))
  end)
  T.it("diff: deep nested objects", function()
    local a = { x = { y = { z = 1 } } }
    local b = { x = { y = { z = 2, w = 3 } } }
    local patch = JP.diff(a, b)
    local res, err = JP.apply(a, patch)
    T.eq(err, nil)
    T.ok(JP.deep_equal(res, b))
  end)
  T.it("diff: completely different docs", function()
    local a = { a = 1 }
    local b = { b = 2 }
    local patch = JP.diff(a, b)
    local res, err = JP.apply(a, patch)
    T.eq(err, nil)
    T.ok(JP.deep_equal(res, b))
  end)
end)

-- ---------------------------------------------------------------------------
-- deep_equal
-- ---------------------------------------------------------------------------

T.describe("JP.deep_equal", function()
  T.it("equal scalars", function()
    T.ok(JP.deep_equal(1, 1))
    T.ok(JP.deep_equal("x", "x"))
    T.ok(JP.deep_equal(true, true))
  end)
  T.it("unequal scalars", function()
    T.ok(not JP.deep_equal(1, 2))
    T.ok(not JP.deep_equal("a", "b"))
  end)
  T.it("equal flat tables", function()
    T.ok(JP.deep_equal({ a = 1, b = 2 }, { a = 1, b = 2 }))
  end)
  T.it("unequal flat tables", function()
    T.ok(not JP.deep_equal({ a = 1 }, { a = 2 }))
  end)
  T.it("extra key in b", function()
    T.ok(not JP.deep_equal({ a = 1 }, { a = 1, b = 2 }))
  end)
  T.it("nested equal", function()
    T.ok(JP.deep_equal({ a = { b = 1 } }, { a = { b = 1 } }))
  end)
  T.it("nested unequal", function()
    T.ok(not JP.deep_equal({ a = { b = 1 } }, { a = { b = 2 } }))
  end)
  T.it("arrays equal", function()
    T.ok(JP.deep_equal({ 1, 2, 3 }, { 1, 2, 3 }))
  end)
  T.it("arrays unequal length", function()
    T.ok(not JP.deep_equal({ 1, 2 }, { 1, 2, 3 }))
  end)
end)
