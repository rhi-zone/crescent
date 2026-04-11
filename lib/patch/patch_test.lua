local M = require("lib.patch")
local T = require("lib.test.assert")

-- ---------------------------------------------------------------------------
-- pointer_parse
-- ---------------------------------------------------------------------------
T.describe("pointer_parse", function()
  T.it("root pointer returns empty table", function()
    local keys = M.pointer_parse("")
    T.eq(#keys, 0, "root has no keys")
  end)

  T.it("single-level pointer", function()
    local keys = M.pointer_parse("/foo")
    T.eq(#keys, 1, "one key")
    T.eq(keys[1], "foo", "key is foo")
  end)

  T.it("two-level pointer", function()
    local keys = M.pointer_parse("/foo/bar")
    T.eq(#keys, 2, "two keys")
    T.eq(keys[1], "foo")
    T.eq(keys[2], "bar")
  end)

  T.it("numeric token", function()
    local keys = M.pointer_parse("/arr/0")
    T.eq(keys[1], "arr")
    T.eq(keys[2], "0")
  end)

  T.it("escaped slash ~1", function()
    local keys = M.pointer_parse("/a~1b")
    T.eq(keys[1], "a/b", "~1 decoded to /")
  end)

  T.it("escaped tilde ~0", function()
    local keys = M.pointer_parse("/a~0b")
    T.eq(keys[1], "a~b", "~0 decoded to ~")
  end)

  T.it("invalid pointer returns nil, err", function()
    local keys, err = M.pointer_parse("no-slash")
    T.eq(keys, nil, "nil on error")
    T.ok(err ~= nil, "error message present")
  end)
end)

-- ---------------------------------------------------------------------------
-- pointer_encode
-- ---------------------------------------------------------------------------
T.describe("pointer_encode", function()
  T.it("empty keys → root pointer", function()
    T.eq(M.pointer_encode({}), "")
  end)

  T.it("single key", function()
    T.eq(M.pointer_encode({"foo"}), "/foo")
  end)

  T.it("multiple keys", function()
    T.eq(M.pointer_encode({"foo", "bar"}), "/foo/bar")
  end)

  T.it("key with slash is escaped", function()
    T.eq(M.pointer_encode({"a/b"}), "/a~1b")
  end)

  T.it("key with tilde is escaped", function()
    T.eq(M.pointer_encode({"a~b"}), "/a~0b")
  end)

  T.it("round-trip parse/encode", function()
    local original = "/foo~0bar/baz~1qux/0"
    local keys = M.pointer_parse(original)
    T.eq(M.pointer_encode(keys), original)
  end)
end)

-- ---------------------------------------------------------------------------
-- get
-- ---------------------------------------------------------------------------
T.describe("get", function()
  local doc = { foo = { bar = 42 }, arr = { 10, 20, 30 }, nil_key = false }

  T.it("get root returns doc", function()
    local v = M.get(doc, "")
    T.eq(v, doc)
  end)

  T.it("get nested value", function()
    local v = M.get(doc, "/foo/bar")
    T.eq(v, 42)
  end)

  T.it("get array element (0-based)", function()
    local v = M.get(doc, "/arr/0")
    T.eq(v, 10)
    local v2 = M.get(doc, "/arr/2")
    T.eq(v2, 30)
  end)

  T.it("get boolean false value", function()
    local v = M.get(doc, "/nil_key")
    T.eq(v, false)
  end)

  T.it("get nonexistent key returns nil, err", function()
    local v, err = M.get(doc, "/does_not_exist")
    T.eq(v, nil)
    T.ok(err ~= nil, "error message")
  end)

  T.it("get deep nonexistent path returns nil, err", function()
    local v, err = M.get(doc, "/foo/nope/deep")
    T.eq(v, nil)
    T.ok(err ~= nil, "error message")
  end)
end)

-- ---------------------------------------------------------------------------
-- set
-- ---------------------------------------------------------------------------
T.describe("set", function()
  T.it("set nested value returns new doc", function()
    local doc = { foo = { bar = 1 } }
    local new_doc = M.set(doc, "/foo/bar", 99)
    T.eq(new_doc.foo.bar, 99)
    T.eq(doc.foo.bar, 1, "original unchanged")
  end)

  T.it("set adds new key", function()
    local doc = { a = 1 }
    local new_doc = M.set(doc, "/b", 2)
    T.eq(new_doc.b, 2)
    T.eq(new_doc.a, 1)
  end)

  T.it("set array element", function()
    local doc = { arr = { 1, 2, 3 } }
    local new_doc = M.set(doc, "/arr/1", 99)
    T.eq(new_doc.arr[2], 99)
    T.eq(doc.arr[2], 2, "original unchanged")
  end)
end)

-- ---------------------------------------------------------------------------
-- remove
-- ---------------------------------------------------------------------------
T.describe("remove", function()
  T.it("remove key returns new doc", function()
    local doc = { a = 1, b = 2 }
    local new_doc = M.remove(doc, "/b")
    T.eq(new_doc.b, nil)
    T.eq(new_doc.a, 1)
    T.eq(doc.b, 2, "original unchanged")
  end)

  T.it("remove array element shifts", function()
    local doc = { arr = { 10, 20, 30 } }
    local new_doc = M.remove(doc, "/arr/1")
    T.eq(#new_doc.arr, 2)
    T.eq(new_doc.arr[1], 10)
    T.eq(new_doc.arr[2], 30)
  end)

  T.it("remove nonexistent key returns nil, err", function()
    local doc = { a = 1 }
    local result, err = M.remove(doc, "/z")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- deep_copy
-- ---------------------------------------------------------------------------
T.describe("deep_copy", function()
  T.it("copies nested tables", function()
    local orig = { a = { b = { c = 3 } } }
    local copy = M.deep_copy(orig)
    T.eq(copy.a.b.c, 3)
    copy.a.b.c = 99
    T.eq(orig.a.b.c, 3, "original unchanged")
  end)

  T.it("primitives returned as-is", function()
    T.eq(M.deep_copy(42), 42)
    T.eq(M.deep_copy("hi"), "hi")
    T.eq(M.deep_copy(true), true)
    T.eq(M.deep_copy(nil), nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: add
-- ---------------------------------------------------------------------------
T.describe("apply add", function()
  T.it("add new key", function()
    local doc = { a = 1 }
    local result = M.apply(doc, {{ op = "add", path = "/b", value = 2 }})
    T.eq(result.b, 2)
    T.eq(result.a, 1)
  end)

  T.it("add to array with -", function()
    local doc = { arr = { 1, 2 } }
    local result = M.apply(doc, {{ op = "add", path = "/arr/-", value = 3 }})
    T.eq(#result.arr, 3)
    T.eq(result.arr[3], 3)
  end)

  T.it("add at array index inserts", function()
    local doc = { arr = { 10, 30 } }
    local result = M.apply(doc, {{ op = "add", path = "/arr/1", value = 20 }})
    T.eq(result.arr[1], 10)
    T.eq(result.arr[2], 20)
    T.eq(result.arr[3], 30)
  end)

  T.it("original doc is not mutated", function()
    local doc = { x = 1 }
    M.apply(doc, {{ op = "add", path = "/y", value = 2 }})
    T.eq(doc.y, nil, "original not mutated")
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: remove
-- ---------------------------------------------------------------------------
T.describe("apply remove", function()
  T.it("remove key", function()
    local doc = { a = 1, b = 2 }
    local result = M.apply(doc, {{ op = "remove", path = "/b" }})
    T.eq(result.b, nil)
    T.eq(result.a, 1)
  end)

  T.it("remove nonexistent key returns nil, err", function()
    local doc = { a = 1 }
    local result, err = M.apply(doc, {{ op = "remove", path = "/z" }})
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: replace
-- ---------------------------------------------------------------------------
T.describe("apply replace", function()
  T.it("replace existing key", function()
    local doc = { a = 1, b = 2 }
    local result = M.apply(doc, {{ op = "replace", path = "/a", value = 99 }})
    T.eq(result.a, 99)
    T.eq(result.b, 2)
  end)

  T.it("replace nonexistent key returns nil, err", function()
    local doc = { a = 1 }
    local result, err = M.apply(doc, {{ op = "replace", path = "/z", value = 5 }})
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: move
-- ---------------------------------------------------------------------------
T.describe("apply move", function()
  T.it("move key", function()
    local doc = { a = { b = 42 }, c = {} }
    local result = M.apply(doc, {{ op = "move", from = "/a/b", path = "/c/d" }})
    T.eq(result.c.d, 42)
    T.eq(result.a.b, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: copy
-- ---------------------------------------------------------------------------
T.describe("apply copy", function()
  T.it("copy key", function()
    local doc = { a = { x = 7 }, b = {} }
    local result = M.apply(doc, {{ op = "copy", from = "/a/x", path = "/b/y" }})
    T.eq(result.b.y, 7)
    T.eq(result.a.x, 7, "original still present")
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: test
-- ---------------------------------------------------------------------------
T.describe("apply test", function()
  T.it("test matching value succeeds", function()
    local doc = { status = "ok" }
    local result, err = M.apply(doc, {{ op = "test", path = "/status", value = "ok" }})
    T.ok(result ~= nil, "result returned")
    T.eq(err, nil)
  end)

  T.it("test mismatched value returns nil, err", function()
    local doc = { status = "fail" }
    local result, err = M.apply(doc, {{ op = "test", path = "/status", value = "ok" }})
    T.eq(result, nil)
    T.ok(err ~= nil, "error returned on mismatch")
  end)

  T.it("test nested object equality", function()
    local doc = { data = { x = 1, y = 2 } }
    local result, err = M.apply(doc, {{ op = "test", path = "/data", value = { x = 1, y = 2 } }})
    T.ok(result ~= nil)
    T.eq(err, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- apply: multiple ops
-- ---------------------------------------------------------------------------
T.describe("apply multiple ops", function()
  T.it("sequence of ops applied in order", function()
    local doc = { a = 1, b = 2, c = 3 }
    local ops = {
      { op = "replace", path = "/a", value = 10 },
      { op = "remove",  path = "/b" },
      { op = "add",     path = "/d", value = 4 },
    }
    local result = M.apply(doc, ops)
    T.eq(result.a, 10)
    T.eq(result.b, nil)
    T.eq(result.c, 3)
    T.eq(result.d, 4)
  end)
end)

-- ---------------------------------------------------------------------------
-- diff
-- ---------------------------------------------------------------------------
T.describe("diff", function()
  T.it("same docs → empty patch", function()
    local doc = { a = 1, b = { c = 2 } }
    local ops = M.diff(doc, doc)
    T.eq(#ops, 0)
  end)

  T.it("added key", function()
    local ops = M.diff({ a = 1 }, { a = 1, b = 2 })
    T.eq(#ops, 1)
    T.eq(ops[1].op, "add")
    T.eq(ops[1].path, "/b")
    T.eq(ops[1].value, 2)
  end)

  T.it("removed key", function()
    local ops = M.diff({ a = 1, b = 2 }, { a = 1 })
    T.eq(#ops, 1)
    T.eq(ops[1].op, "remove")
    T.eq(ops[1].path, "/b")
  end)

  T.it("changed value", function()
    local ops = M.diff({ a = 1, b = 2 }, { a = 1, b = 3 })
    T.eq(#ops, 1)
    T.eq(ops[1].op, "replace")
    T.eq(ops[1].path, "/b")
    T.eq(ops[1].value, 3)
  end)

  T.it("nested object change", function()
    local a = { outer = { inner = 1 } }
    local b = { outer = { inner = 2 } }
    local ops = M.diff(a, b)
    T.eq(#ops, 1)
    T.eq(ops[1].op, "replace")
    T.eq(ops[1].path, "/outer/inner")
    T.eq(ops[1].value, 2)
  end)

  T.it("multiple changes", function()
    local a = { a = 1, b = 2 }
    local b = { a = 1, b = 3, c = 4 }
    local ops = M.diff(a, b)
    -- should have replace /b and add /c
    local by_path = {}
    for _, op in ipairs(ops) do by_path[op.path] = op end
    T.ok(by_path["/b"] ~= nil, "replace /b present")
    T.eq(by_path["/b"].op, "replace")
    T.eq(by_path["/b"].value, 3)
    T.ok(by_path["/c"] ~= nil, "add /c present")
    T.eq(by_path["/c"].op, "add")
    T.eq(by_path["/c"].value, 4)
  end)
end)

-- ---------------------------------------------------------------------------
-- round-trip: apply(diff(a,b), a) ≡ b
-- ---------------------------------------------------------------------------
T.describe("diff round-trip", function()
  local function round_trip(a, b, label)
    local ops = M.diff(a, b)
    local result, err = M.apply(a, ops)
    T.ok(err == nil, label .. ": no error: " .. tostring(err))
    -- deep equality check via re-diff
    local check_ops = M.diff(result, b)
    T.eq(#check_ops, 0, label .. ": result equals b")
  end

  T.it("flat object round-trip", function()
    round_trip({ a = 1, b = 2 }, { a = 1, b = 3, c = 4 }, "flat")
  end)

  T.it("nested object round-trip", function()
    round_trip(
      { outer = { x = 1, y = 2 } },
      { outer = { x = 1, y = 99 }, z = true },
      "nested"
    )
  end)

  T.it("remove all keys round-trip", function()
    round_trip({ a = 1, b = 2 }, {}, "remove all")
  end)

  T.it("add all keys round-trip", function()
    round_trip({}, { a = 1, b = 2 }, "add all")
  end)

  T.it("identical docs round-trip (empty patch)", function()
    local doc = { x = { y = { z = 42 } } }
    local ops = M.diff(doc, doc)
    T.eq(#ops, 0)
    local result = M.apply(doc, ops)
    local check = M.diff(result, doc)
    T.eq(#check, 0, "result equals original")
  end)
end)
